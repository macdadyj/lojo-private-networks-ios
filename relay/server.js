"use strict";

// LOJO Networks relay for iPhone Remote Controller.
// A spare iPhone registers here, and the controller phone lists it, sends
// play/stop/volume/sleep commands, edits schedules, and reads the latest
// view-only screen frame. No secrets are baked in. Callers share a network
// code in the X-Lojo-Network header. Bind to loopback unless BIND is set.
// Run on the site gateway: BIND=0.0.0.0 PORT=8791 node relay/server.js

const fs = require("fs");
const http = require("http");

const BIND = process.env.BIND || "127.0.0.1";
const PORT = Number(process.env.PORT || 8791);
const ONLINE_MS = Number(process.env.ONLINE_MS || 12000);
const MAX_BODY = 2 * 1024 * 1024;

const rooms = new Map();

function room(code) {
  let found = rooms.get(code);
  if (!found) {
    found = { phones: new Map() };
    rooms.set(code, found);
  }
  return found;
}

function publicPhone(phone, now) {
  return {
    id: phone.id,
    name: phone.name,
    online: now - phone.lastSeenMs < ONLINE_MS,
    batteryPercent: phone.batteryPercent,
    charging: !!phone.charging,
    playback: phone.playback || null,
    schedules: phone.schedules || [],
    scheduleRevision: phone.scheduleRevision || 0,
    music: phone.music || [],
    shortcuts: phone.shortcuts || [],
    lastError: phone.lastError || null,
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(Object.assign(new Error("body too large"), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function send(res, status, body, type) {
  const payload = body == null ? Buffer.alloc(0) : Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": type || (Buffer.isBuffer(body) ? "application/octet-stream" : "application/json; charset=utf-8"),
    "Content-Length": String(payload.length),
    "Cache-Control": "no-store",
  });
  res.end(payload);
}

function fail(res, status, message) {
  send(res, status, { ok: false, error: message });
}

async function handle(req, res) {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  const parts = url.pathname.split("/").filter(Boolean);
  if (req.method === "GET" && parts.length === 1 && parts[0] === "health") {
    send(res, 200, { ok: true, service: "lojo-remote-relay" });
    return;
  }
  if (parts[0] !== "v1" || parts[1] !== "phones") {
    fail(res, 404, "not found");
    return;
  }
  const code = String(req.headers["x-lojo-network"] || "");
  if (!code) {
    fail(res, 401, "missing network code");
    return;
  }
  const book = room(code);
  const now = Date.now();

  if (req.method === "GET" && parts.length === 2) {
    const phones = [...book.phones.values()].map((phone) => publicPhone(phone, now));
    phones.sort((a, b) => a.name.localeCompare(b.name));
    send(res, 200, { phones });
    return;
  }

  if (req.method === "POST" && parts.length === 2) {
    const body = JSON.parse((await readBody(req)).toString("utf8") || "{}");
    const id = String(body.id || "");
    const name = String(body.name || "").trim();
    if (!id || !name) {
      fail(res, 400, "id and name are required");
      return;
    }
    const existing = book.phones.get(id);
    const phone = existing || {
      id,
      commands: [],
      commandSeq: 0,
      schedules: [],
      scheduleRevision: 0,
      shortcuts: [],
      screen: null,
    };
    phone.name = name;
    phone.batteryPercent = numberOrNull(body.batteryPercent);
    phone.charging = !!body.charging;
    phone.lastSeenMs = now;
    phone.mode = "remote-controller";
    if (Array.isArray(body.shortcuts)) phone.shortcuts = sanitizeShortcuts(body.shortcuts);
    if (!existing) {
      phone.playback = null;
      phone.music = [];
      phone.lastError = null;
      if (Array.isArray(body.schedules) && body.schedules.length) {
        phone.schedules = body.schedules;
        phone.scheduleRevision = 1;
      }
      book.phones.set(id, phone);
    }
    send(res, 200, { phone: publicPhone(phone, now) });
    return;
  }

  const id = parts[2];
  const phone = id ? book.phones.get(id) : null;
  if (!phone) {
    fail(res, 404, "phone not registered");
    return;
  }
  const action = parts[3] || "";

  if (req.method === "GET" && parts.length === 3) {
    send(res, 200, { phone: publicPhone(phone, now) });
    return;
  }

  if (req.method === "POST" && action === "heartbeat" && parts.length === 4) {
    const body = JSON.parse((await readBody(req)).toString("utf8") || "{}");
    phone.lastSeenMs = now;
    if ("batteryPercent" in body) phone.batteryPercent = numberOrNull(body.batteryPercent);
    if ("charging" in body) phone.charging = !!body.charging;
    if ("playback" in body) phone.playback = body.playback;
    if ("music" in body) phone.music = Array.isArray(body.music) ? body.music : [];
    if (Array.isArray(body.shortcuts)) phone.shortcuts = sanitizeShortcuts(body.shortcuts);
    if ("lastError" in body) phone.lastError = body.lastError ? String(body.lastError) : null;
    const ack = new Set(Array.isArray(body.ack) ? body.ack.map(String) : []);
    if (ack.size) phone.commands = phone.commands.filter((command) => !ack.has(command.id));
    send(res, 200, {
      commands: phone.commands,
      schedules: phone.schedules,
      scheduleRevision: phone.scheduleRevision,
    });
    return;
  }

  if (req.method === "POST" && action === "commands" && parts.length === 4) {
    const body = JSON.parse((await readBody(req)).toString("utf8") || "{}");
    const kind = String(body.kind || "");
    if (!["play", "stop", "setVolume", "setSleep", "runShortcut"].includes(kind)) {
      fail(res, 400, "unknown command");
      return;
    }
    if (kind === "runShortcut" && !String(body.shortcutName || "").trim()) {
      fail(res, 400, "shortcut name is required");
      return;
    }
    phone.commandSeq += 1;
    const command = {
      id: "c" + phone.commandSeq,
      seq: phone.commandSeq,
      kind,
      soundID: body.soundID ? String(body.soundID) : null,
      volume: typeof body.volume === "number" ? body.volume : null,
      sleepMinutes: Number.isInteger(body.sleepMinutes) ? body.sleepMinutes : null,
      shortcutName: body.shortcutName ? String(body.shortcutName).trim() : null,
    };
    phone.commands.push(command);
    send(res, 200, { command });
    return;
  }

  if (action === "schedules" && parts.length === 4) {
    if (req.method === "GET") {
      send(res, 200, { schedules: phone.schedules, scheduleRevision: phone.scheduleRevision });
      return;
    }
    if (req.method === "PUT") {
      const body = JSON.parse((await readBody(req)).toString("utf8") || "{}");
      if (!Array.isArray(body.schedules)) {
        fail(res, 400, "schedules must be a list");
        return;
      }
      phone.schedules = body.schedules;
      phone.scheduleRevision += 1;
      send(res, 200, { schedules: phone.schedules, scheduleRevision: phone.scheduleRevision });
      return;
    }
  }

  if (action === "screen" && parts.length === 4) {
    if (req.method === "POST") {
      const body = await readBody(req);
      if (!body.length) {
        fail(res, 400, "empty frame");
        return;
      }
      phone.screen = body;
      phone.lastSeenMs = now;
      send(res, 200, { ok: true, bytes: body.length });
      return;
    }
    if (req.method === "GET") {
      if (!phone.screen) {
        send(res, 204, null);
        return;
      }
      send(res, 200, phone.screen, "image/jpeg");
      return;
    }
  }

  fail(res, 404, "not found");
}

function sanitizeShortcuts(list) {
  return list.slice(0, 40).map((item) => ({
    name: String((item && item.name) || "").trim().slice(0, 80),
    builtin: !!(item && item.builtin),
    summary: String((item && item.summary) || "").slice(0, 160),
  })).filter((item) => item.name);
}

function numberOrNull(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, Math.round(value)));
}

function start(port, bind) {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      if (res.headersSent) return;
      const status = error && error.status ? error.status : 400;
      fail(res, status, status === 413 ? "body too large" : "bad request");
    });
  });
  server.listen(port, bind);
  return server;
}

async function selfTest() {
  rooms.clear();
  const server = start(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const code = "self-test";
  const headers = { "Content-Type": "application/json", "X-Lojo-Network": code };
  async function call(method, path, body, extra) {
    const response = await fetch(base + path, {
      method,
      headers: extra || headers,
      body: body == null ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body),
    });
    const type = response.headers.get("content-type") || "";
    const buffer = Buffer.from(await response.arrayBuffer());
    const parsed = type.includes("json") && buffer.length ? JSON.parse(buffer.toString("utf8")) : null;
    return { status: response.status, parsed, buffer };
  }
  const health = await call("GET", "/health", null, {});
  if (health.status !== 200 || !health.parsed.ok) throw new Error("health failed");
  const missing = await call("GET", "/v1/phones", null, {});
  if (missing.status !== 401) throw new Error("network code was not required");
  const registered = await call("POST", "/v1/phones", {
    id: "phone-1",
    name: "Spare iPhone",
    batteryPercent: 81,
    charging: false,
    schedules: [],
  });
  if (registered.status !== 200 || !registered.parsed.phone.online) throw new Error("register failed");
  const listed = await call("GET", "/v1/phones");
  if (listed.parsed.phones.length !== 1 || listed.parsed.phones[0].batteryPercent !== 81) {
    throw new Error("list failed");
  }
  const hidden = await call("GET", "/v1/phones", null, { "X-Lojo-Network": "other-room" });
  if (hidden.parsed.phones.length !== 0) throw new Error("rooms were not isolated");
  const play = await call("POST", "/v1/phones/phone-1/commands", { kind: "play", soundID: "white-noise" });
  if (play.status !== 200 || play.parsed.command.kind !== "play") throw new Error("command failed");
  const beat = await call("POST", "/v1/phones/phone-1/heartbeat", {
    batteryPercent: 80,
    charging: true,
    playback: { playing: false, volume: 0.6, source: "none" },
    music: [],
    ack: [],
  });
  if (beat.parsed.commands.length !== 1 || beat.parsed.commands[0].soundID !== "white-noise") {
    throw new Error("heartbeat did not deliver the command");
  }
  const acked = await call("POST", "/v1/phones/phone-1/heartbeat", {
    batteryPercent: 80,
    charging: true,
    playback: { playing: true, soundID: "white-noise", title: "White Noise", volume: 0.6, source: "bundled" },
    ack: [play.parsed.command.id],
  });
  if (acked.parsed.commands.length !== 0) throw new Error("ack did not clear the command");
  const named = await call("POST", "/v1/phones/phone-1/heartbeat", {
    batteryPercent: 80,
    charging: true,
    playback: { playing: false, volume: 0.6, source: "none" },
    shortcuts: [{ name: "Bedtime white noise", builtin: true, summary: "Play white noise at bedtime." }],
    ack: [],
  });
  if (!named.parsed) throw new Error("shortcut heartbeat failed");
  const listedShortcuts = await call("GET", "/v1/phones");
  const shortcutNames = (listedShortcuts.parsed.phones[0].shortcuts || []).map((item) => item.name);
  if (shortcutNames.join(",") !== "Bedtime white noise") throw new Error("shortcut names were not stored");
  const run = await call("POST", "/v1/phones/phone-1/commands", {
    kind: "runShortcut",
    shortcutName: "Bedtime white noise",
  });
  if (run.status !== 200 || run.parsed.command.shortcutName !== "Bedtime white noise") {
    throw new Error("run shortcut failed");
  }
  const saved = await call("PUT", "/v1/phones/phone-1/schedules", {
    schedules: [{ id: "night", soundID: "white-noise", startMinutes: 1200, stopMinutes: 360, enabled: true, volume: 0.6 }],
  });
  if (saved.parsed.scheduleRevision !== 1 || saved.parsed.schedules[0].startMinutes !== 1200) {
    throw new Error("schedule save failed");
  }
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  const posted = await fetch(base + "/v1/phones/phone-1/screen", {
    method: "POST",
    headers: { "X-Lojo-Network": code, "Content-Type": "image/jpeg" },
    body: jpeg,
  });
  if (posted.status !== 200) throw new Error("frame post failed");
  const frame = await call("GET", "/v1/phones/phone-1/screen");
  if (frame.status !== 200 || !frame.buffer.equals(jpeg)) throw new Error("frame get failed");
  const gone = await call("GET", "/v1/phones/missing/screen");
  if (gone.status !== 404) throw new Error("missing phone was not 404");
  server.close();
  console.log("relay self-test ok");
}

if (process.argv.includes("--self-test")) {
  selfTest().catch((error) => {
    console.error(error && error.message ? error.message : "relay self-test failed");
    process.exit(1);
  });
} else if (require.main === module) {
  const server = start(PORT, BIND);
  server.on("listening", () => {
    const actual = server.address().port;
    fs.writeSync(1, `lojo remote relay listening on ${BIND}:${actual}\n`);
  });
}
