"use strict";

// REST front for Pub-Node cameras + GPIO via Cloud Run controlState.
// Does not talk to App Engine Flex.
const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const express = require("express");
const io = require("socket.io-client");

const PUBNODE_URL = process.env.PUBNODE_URL || "http://100.96.1.18:8788/";
const BIND = process.env.BIND || "0.0.0.0";
const PORT = Number(process.env.PORT || 8801);
const STATE_DIR =
  process.env.STATE_DIR || path.join(os.homedir(), ".local", "state", "ranch-field-api");
const LAN_PREFIXES = (process.env.LAN_PREFIXES || "192.168.").split(",");
const OVERLAY_PREFIXES = (process.env.OVERLAY_PREFIXES || "100.").split(",");
const MAX_EVENTS = 300;
const TLS_PORT = Number(process.env.TLS_PORT || 8443);
const TLS_DIR = process.env.TLS_DIR || path.join(STATE_DIR, "tls");
const VERSION = "1.4.0";
const RELIST_MS = 60 * 1000;
const HEADER_GPIO_PINS = new Set([3, 5, 7, 8, 10, 11, 12, 13, 15, 16, 18, 19, 21, 22, 23, 24, 26, 27, 28, 29, 31, 32, 33, 35, 36, 37, 38, 40]);
const startedAt = new Date().toISOString();

const devices = new Map(); // socketID -> sanitized public record
const stills = new Map(); // socketID -> { mime, buf, capturedAt }
const rawDevices = new Map(); // socketID -> last full device payload

// v1 roster: stable by device name so a reconnect (new socketID) is the same device.
const known = new Map(); // key -> { key, socketID, online, firstSeenAt, onlineSince, offlineSince, lastUpdateAt, location }
const socketToKey = new Map();
let events = [];
let eventSeq = 0;
const hub = { connected: false, since: null, lastError: null, lastListAt: null };

function locProps(data) {
  return (data && data.location && data.location.properties) || {};
}

function gpioPinsOf(data) {
  const raw = (data && data.raspberrypi && data.raspberrypi.gpiopins) || {};
  const out = {};
  Object.keys(raw).forEach((pin) => {
    const n = Number(raw[pin]);
    if (n === 0 || n === 1) out[String(pin)] = n;
  });
  const site = String(locProps(data).site || "").toLowerCase();
  // Vision / bluebox Cloud Run nodes drive header pin 11 (GPIO 17) even when the live map is empty.
  if (!Object.keys(out).length && (site === "vision" || site === "bluebox")) {
    out["11"] = 0;
  }
  return out;
}

function locationOf(data) {
  const loc = data && data.location;
  const coords = loc && loc.geometry && loc.geometry.coordinates;
  if (!Array.isArray(coords) || coords.length < 2) return null;
  const lon = Number(coords[0]);
  const lat = Number(coords[1]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180 || (lat === 0 && lon === 0)) return null;
  const props = locProps(data);
  return {
    lat: lat,
    lon: lon,
    source: props.source ? String(props.source) : null,
  };
}

function publicDevice(data) {
  const client = (data && data.client) || {};
  const id = String(client.socketID || "");
  const props = locProps(data);
  const webcam = (data && data.webcam) || {};
  const last = webcam.lastCapture || {};
  const hasStill = !!(last.dataBase64 && String(last.dataBase64).length > 80);
  const gpioPins = gpioPinsOf(data);
  return {
    socketID: id,
    name: String(props.name || props.site || client.name || id),
    site: String(props.site || ""),
    webcamEnabled: !!webcam.enabled,
    lastCaptureError: webcam.lastCaptureError ? String(webcam.lastCaptureError) : null,
    capturedAt: last.capturedAt ? String(last.capturedAt) : null,
    hasStill: hasStill,
    lastSeenAt: data && data.lastSeenAt ? String(data.lastSeenAt) : null,
    stillURL: hasStill && id ? "/devices/" + encodeURIComponent(id) + "/still" : null,
    gpioPins: gpioPins,
    gpio: Object.keys(gpioPins).length > 0,
  };
}

function stripCaptureB64(data) {
  if (!data || !data.webcam || !data.webcam.lastCapture) return data;
  if (data.webcam.lastCapture.dataBase64) {
    const copy = Object.assign({}, data.webcam.lastCapture);
    delete copy.dataBase64;
    data.webcam.lastCapture = copy;
  }
  return data;
}

// ---------- persistence ----------

let saveTimer = null;
function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true });
      const knownOut = Array.from(known.values()).map((k) => ({
        key: k.key,
        public: k.public,
        firstSeenAt: k.firstSeenAt,
        offlineSince: k.offlineSince || new Date().toISOString(),
        lastUpdateAt: k.lastUpdateAt,
        location: k.location,
      }));
      const tmp = path.join(STATE_DIR, "state.json.tmp");
      fs.writeFileSync(tmp, JSON.stringify({ events: events, known: knownOut, eventSeq: eventSeq }));
      fs.renameSync(tmp, path.join(STATE_DIR, "state.json"));
    } catch (e) {
      console.log("state save failed", String(e && e.message ? e.message : e));
    }
  }, 2000);
}

function loadState() {
  try {
    const raw = fs.readFileSync(path.join(STATE_DIR, "state.json"), "utf8");
    const parsed = JSON.parse(raw);
    events = Array.isArray(parsed.events) ? parsed.events.slice(-MAX_EVENTS) : [];
    eventSeq = Number(parsed.eventSeq) || events.length;
    (parsed.known || []).forEach((k) => {
      if (!k || !k.key || !k.public) return;
      known.set(k.key, {
        key: k.key,
        socketID: null,
        public: k.public,
        online: false,
        firstSeenAt: k.firstSeenAt || null,
        onlineSince: null,
        offlineSince: k.offlineSince || null,
        lastUpdateAt: k.lastUpdateAt || null,
        location: k.location || null,
        lastSeenInList: 0,
      });
    });
  } catch (e) {
    /* first run */
  }
}

// ---------- events ----------

function addEvent(type, fields) {
  eventSeq += 1;
  const ev = Object.assign(
    { id: String(eventSeq), type: type, at: new Date().toISOString() },
    fields || {}
  );
  events.push(ev);
  if (events.length > MAX_EVENTS) events = events.slice(-MAX_EVENTS);
  scheduleSave();
  return ev;
}

function deviceKeyOf(pub) {
  return String(pub.name || pub.socketID);
}

// ---------- ingest ----------

let listGeneration = 0;

function ingest(raw) {
  let data = raw;
  if (typeof raw === "string") {
    try {
      data = JSON.parse(raw);
    } catch (e) {
      return;
    }
  }
  if (!data || !data.client || !data.client.socketID) return;
  if (data.client.type && data.client.type !== "device") return;
  const id = String(data.client.socketID);
  const webcam = data.webcam || {};
  const last = webcam.lastCapture || {};
  if (last.dataBase64 && String(last.dataBase64).length > 80) {
    try {
      stills.set(id, {
        mime: last.mime || "image/jpeg",
        buf: Buffer.from(String(last.dataBase64), "base64"),
        capturedAt: last.capturedAt || new Date().toISOString(),
      });
    } catch (e) {
      /* ignore bad base64 */
    }
  }
  const stored = JSON.parse(JSON.stringify(data));
  stripCaptureB64(stored);
  rawDevices.set(id, stored);
  const pub = publicDevice(data);
  devices.set(id, pub);
  trackKnown(id, pub, data);
}

function trackKnown(id, pub, data) {
  const key = deviceKeyOf(pub);
  const now = new Date().toISOString();
  let k = known.get(key);
  const previous = k ? k.public : null;
  if (!k) {
    k = {
      key: key,
      socketID: id,
      public: pub,
      online: false,
      firstSeenAt: now,
      onlineSince: null,
      offlineSince: null,
      lastUpdateAt: null,
      location: null,
      lastSeenInList: 0,
    };
    known.set(key, k);
  }
  if (k.socketID && k.socketID !== id) socketToKey.delete(k.socketID);
  k.socketID = id;
  socketToKey.set(id, key);
  k.public = pub;
  k.lastUpdateAt = pub.lastSeenAt || now;
  k.lastSeenInList = listGeneration;
  const loc = locationOf(data);
  if (loc) k.location = loc;
  if (!k.online) {
    k.online = true;
    k.onlineSince = now;
    k.offlineSince = null;
    addEvent("device.online", { device: key, site: pub.site });
  }
  if (previous) {
    if (pub.capturedAt && pub.hasStill && pub.capturedAt !== previous.capturedAt) {
      addEvent("capture.completed", { device: key, capturedAt: pub.capturedAt });
    }
    if (pub.lastCaptureError && pub.lastCaptureError !== previous.lastCaptureError) {
      addEvent("capture.failed", { device: key, detail: pub.lastCaptureError });
    }
  }
  scheduleSave();
}

function markOffline(key, reason) {
  const k = known.get(key);
  if (!k || !k.online) return;
  k.online = false;
  k.offlineSince = new Date().toISOString();
  addEvent("device.offline", { device: key, site: k.public.site, detail: reason || null });
}

// ---------- hub socket ----------

const socket = io.connect(PUBNODE_URL, {
  transports: ["websocket", "polling"],
  upgrade: true,
  reconnection: true,
});

socket.on("connect", () => {
  console.log("pub-node connected", PUBNODE_URL, socket.id);
  hub.connected = true;
  hub.since = new Date().toISOString();
  hub.lastError = null;
  addEvent("hub.connected", {});
});
socket.on("disconnect", (reason) => {
  if (hub.connected) addEvent("hub.disconnected", { detail: String(reason || "") });
  hub.connected = false;
  hub.since = new Date().toISOString();
});
socket.on("connect_error", (err) => {
  hub.lastError = String(err && err.message ? err.message : err);
  console.log("pub-node connect_error", hub.lastError);
});
socket.on("error", (err) => {
  console.log("pub-node error", String(err));
});

socket.on("nodeTypeRequest", (data) => {
  const sid = data && data.client && data.client.socketID;
  socket.emit("authenticate", {
    client: {
      uid: "",
      type: "user",
      socketID: sid,
      secret: {
        username: "ranch-field",
        datatohide: "",
        passwordhash: "",
        encryptedpasswordhash: [],
        recoverypublickey: "",
      },
      record: "",
    },
  });
});

let registered = false;

function relist() {
  if (!registered || !socket.connected) return;
  listGeneration += 1;
  const gen = listGeneration;
  hub.lastListAt = new Date().toISOString();
  socket.emit("perform list function", "list devices");
  // Anything the hub did not re-send after a fresh list is no longer on the hub.
  setTimeout(() => {
    if (gen !== listGeneration || !socket.connected) return;
    known.forEach((k) => {
      if (k.online && k.lastSeenInList < gen) markOffline(k.key, "not in hub roster");
    });
  }, 8000);
}

socket.on("connect-reg", (data) => {
  socket.emit("secret", data);
  registered = true;
  relist();
});
socket.on("disconnect", () => {
  registered = false;
});
// The hub does not push a device that drops and rejoins within a second or two, so re-list
// periodically and shortly after any device leaves.
setInterval(relist, RELIST_MS);

socket.on("build webpage", (payload) => ingest(payload));
socket.on("remove webpage object", (socketID) => {
  const id = String(socketID || "");
  devices.delete(id);
  stills.delete(id);
  rawDevices.delete(id);
  const key = socketToKey.get(id);
  if (key) {
    socketToKey.delete(id);
    const k = known.get(key);
    if (k && k.socketID === id) markOffline(key, "left the hub");
  }
  setTimeout(relist, 6000);
});

// ---------- http ----------

function peerAddress(req) {
  return String((req.socket && req.socket.remoteAddress) || "").replace(/^::ffff:/, "");
}

// A phone on the VPN that targets the LAN address still arrives from its overlay address, so the
// peer decides "overlay" first; the local address only breaks ties for direct LAN clients.
function arrivalPath(req) {
  const local = String((req.socket && req.socket.localAddress) || "").replace(/^::ffff:/, "");
  const peer = peerAddress(req);
  if (local === "127.0.0.1" || local === "::1") return "local";
  if (OVERLAY_PREFIXES.some((p) => peer.startsWith(p) || local.startsWith(p))) return "overlay";
  if (LAN_PREFIXES.some((p) => local.startsWith(p))) return "lan";
  return "other";
}

function schemeOf(req) {
  return req.socket && req.socket.encrypted ? "https" : "http";
}

// ---------- tls ----------

// HTTPS is additive: plain HTTP on PORT stays for the Ranch Field app and legacy clients.
// Keys are read from TLS_DIR (0600, created by scripts/gateway-tls.sh) and never logged.
let tls = null; // { key, cert, caSha256, leafSha256, leafNotAfter }

function loadTLS() {
  try {
    const key = fs.readFileSync(path.join(TLS_DIR, "server.key"));
    const cert = fs.readFileSync(path.join(TLS_DIR, "fullchain.crt"));
    const leaf = new crypto.X509Certificate(fs.readFileSync(path.join(TLS_DIR, "server.crt")));
    const ca = new crypto.X509Certificate(fs.readFileSync(path.join(TLS_DIR, "ca.crt")));
    tls = {
      key: key,
      cert: cert,
      caSha256: crypto.createHash("sha256").update(ca.raw).digest("hex"),
      leafSha256: crypto.createHash("sha256").update(leaf.raw).digest("hex"),
      leafNotAfter: new Date(leaf.validTo).toISOString(),
    };
    return true;
  } catch (e) {
    if (e.code !== "ENOENT") console.log("tls load failed:", e.code || e.message);
    tls = null;
    return false;
  }
}

function tlsInfo() {
  if (!tls) return { enabled: false };
  return {
    enabled: true,
    port: TLS_PORT,
    caSha256: tls.caSha256,
    leafSha256: tls.leafSha256,
    leafNotAfter: tls.leafNotAfter,
  };
}

function v1Device(k) {
  const pub = k.public;
  const sid = k.online ? k.socketID : null;
  const hasStill = !!(sid && stills.has(sid));
  return {
    key: k.key,
    socketID: sid,
    name: pub.name,
    site: pub.site,
    online: !!k.online,
    firstSeenAt: k.firstSeenAt,
    onlineSince: k.online ? k.onlineSince : null,
    offlineSince: k.online ? null : k.offlineSince,
    lastUpdateAt: k.lastUpdateAt,
    camera: {
      enabled: !!pub.webcamEnabled,
      hasStill: hasStill,
      capturedAt: pub.capturedAt,
      lastError: pub.lastCaptureError,
      stillURL: hasStill ? "/devices/" + encodeURIComponent(sid) + "/still" : null,
    },
    gpio: Object.keys(pub.gpioPins || {})
      .sort((a, b) => Number(a) - Number(b))
      .map((pin) => ({ pin: pin, value: pub.gpioPins[pin] })),
    location: k.location,
  };
}

function eventDeviceKey(id) {
  const key = socketToKey.get(id);
  if (key) return key;
  const d = devices.get(id);
  return d ? deviceKeyOf(d) : id;
}

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "32kb" }));
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.status(204).end();
  next();
});

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "ranch-field-api",
    gpio: true,
    flex: false,
    pubnode: PUBNODE_URL,
    pubnodeConnected: !!socket.connected,
    devices: devices.size,
  });
});

app.get("/v1/network", (req, res) => {
  let online = 0;
  let offline = 0;
  known.forEach((k) => (k.online ? (online += 1) : (offline += 1)));
  res.json({
    ok: true,
    version: VERSION,
    gateway: { name: os.hostname(), startedAt: startedAt, uptimeSec: Math.round(process.uptime()) },
    hub: {
      connected: !!socket.connected,
      since: hub.since,
      lastError: socket.connected ? null : hub.lastError,
      lastListAt: hub.lastListAt,
    },
    devices: { online: online, offline: offline, total: online + offline },
    arrivedVia: arrivalPath(req),
    seenFrom: peerAddress(req),
    scheme: schemeOf(req),
    tls: tlsInfo(),
    serverTime: new Date().toISOString(),
  });
});

app.get("/v1/devices", (_req, res) => {
  const list = Array.from(known.values())
    .map(v1Device)
    .sort((a, b) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return String(a.name).localeCompare(String(b.name));
    });
  res.json({ ok: true, hubConnected: !!socket.connected, devices: list });
});

app.get("/v1/events", (req, res) => {
  const limit = Math.max(1, Math.min(MAX_EVENTS, Number(req.query.limit) || 100));
  const device = req.query.device ? String(req.query.device) : null;
  let list = events;
  if (device) list = list.filter((e) => e.device === device);
  res.json({ ok: true, events: list.slice(-limit).reverse() });
});

app.get("/devices", (_req, res) => {
  const list = Array.from(devices.values()).sort((a, b) =>
    String(a.name).localeCompare(String(b.name))
  );
  res.json({ ok: true, gpio: true, flex: false, devices: list });
});

app.get("/devices/:id", (req, res) => {
  const d = devices.get(req.params.id);
  if (!d) return res.status(404).json({ ok: false, error: "unknown device" });
  res.json({ ok: true, gpio: true, flex: false, device: d });
});

app.get("/devices/:id/still", (req, res) => {
  const still = stills.get(req.params.id);
  if (!still) return res.status(404).json({ ok: false, error: "no still" });
  res.setHeader("Content-Type", still.mime || "image/jpeg");
  res.setHeader("Cache-Control", "no-store");
  res.send(still.buf);
});

app.post("/devices/:id/capture", (req, res) => {
  const id = req.params.id;
  if (!devices.has(id)) {
    return res.status(404).json({ ok: false, error: "unknown device" });
  }
  const d = devices.get(id);
  if (!d.webcamEnabled) {
    return res.status(409).json({ ok: false, error: "webcam disabled on device" });
  }
  if (!socket.connected) {
    return res.status(503).json({ ok: false, error: "cloud hub not connected" });
  }
  socket.emit("captureRequest", {
    client: { socketID: id, type: "device" },
    webcam: { enabled: true },
  });
  addEvent("capture.requested", { device: eventDeviceKey(id), via: arrivalPath(req), scheme: schemeOf(req) });
  res.json({ ok: true, gpio: true, requested: id });
});

app.post("/devices/:id/gpio", (req, res) => {
  const id = req.params.id;
  if (!devices.has(id) || !rawDevices.has(id)) {
    return res.status(404).json({ ok: false, error: "unknown device" });
  }
  const pin = String((req.body && req.body.pin) != null ? req.body.pin : "");
  const value = Number(req.body && req.body.value);
  // Device agents use rpi-gpio's physical numbering: pins are 40-pin header positions.
  if (!/^\d+$/.test(pin) || !HEADER_GPIO_PINS.has(Number(pin))) {
    return res.status(400).json({ ok: false, error: "pin must be a GPIO header pin number" });
  }
  if (value !== 0 && value !== 1) {
    return res.status(400).json({ ok: false, error: "value must be 0 or 1" });
  }
  if (!socket.connected) {
    return res.status(503).json({ ok: false, error: "cloud hub not connected" });
  }
  const payload = JSON.parse(JSON.stringify(rawDevices.get(id)));
  stripCaptureB64(payload);
  if (!payload.client) payload.client = {};
  payload.client.socketID = id;
  payload.client.type = "device";
  if (!payload.raspberrypi) payload.raspberrypi = {};
  if (!payload.raspberrypi.gpiopins) payload.raspberrypi.gpiopins = {};
  payload.raspberrypi.gpiopins[pin] = value;
  rawDevices.set(id, payload);
  const pub = publicDevice(payload);
  devices.set(id, pub);
  const key = socketToKey.get(id);
  if (key && known.has(key)) known.get(key).public = pub;
  socket.emit("controlState", payload);
  addEvent("gpio.set", {
    device: eventDeviceKey(id),
    pin: pin,
    value: value,
    via: arrivalPath(req),
    scheme: schemeOf(req),
  });
  res.json({ ok: true, flex: false, pin: pin, value: value, device: pub });
});

app.use((_req, res) => {
  res.status(404).json({ ok: false, error: "not found" });
});

loadState();
app.listen(PORT, BIND, () => {
  console.log("ranch-field-api", VERSION, BIND + ":" + PORT, "pubnode", PUBNODE_URL, "gpio=true flex=false");
});

let tlsServer = null;
function startTLS() {
  if (tlsServer || !tls) return;
  tlsServer = https.createServer({ key: tls.key, cert: tls.cert, minVersion: "TLSv1.2" }, app);
  tlsServer.on("tlsClientError", (err) => console.log("tls client error:", err.code || err.message));
  tlsServer.listen(TLS_PORT, BIND, () => {
    console.log("https", BIND + ":" + TLS_PORT, "ca", tls.caSha256.slice(0, 16), "leaf until", tls.leafNotAfter);
  });
}

if (loadTLS()) startTLS();
else console.log("https disabled: no certificate in", TLS_DIR, "(run scripts/gateway-tls.sh init)");

// scripts/gateway-tls.sh rotate sends SIGHUP: swap certificates without dropping HTTP clients.
process.on("SIGHUP", () => {
  if (!loadTLS()) return console.log("SIGHUP: no certificate; https unchanged");
  if (tlsServer) {
    tlsServer.setSecureContext({ key: tls.key, cert: tls.cert });
    console.log("SIGHUP: certificate reloaded, leaf until", tls.leafNotAfter);
  } else {
    startTLS();
  }
});
