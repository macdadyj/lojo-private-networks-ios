"use strict";

// Standalone iPhone Remote Controller relay.
// On a site, the same rooms run inside the gateway (sidecar/server.js) on
// HTTPS :8443. This process is for tests and a loopback relay.
// Bind to loopback unless BIND is set. No secrets are baked in.

const fs = require("fs");
const http = require("http");
const { createRelay, readRaw } = require("./rooms");

const BIND = process.env.BIND || "127.0.0.1";
const PORT = Number(process.env.PORT || 8791);
const relay = createRelay({ onlineMs: Number(process.env.ONLINE_MS || 12000) });

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
  const body = await readRaw(req);
  const result = await relay.dispatch(req.method, url.pathname, req.headers, body);
  send(res, result.status, result.body, result.type);
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
  relay.rooms.clear();
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
