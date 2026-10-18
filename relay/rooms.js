"use strict";

// Shared iPhone Remote Controller rooms. The standalone relay and the site
// gateway both use this. Callers share a network code in X-Lojo-Network.
// No secrets are baked in.

const ONLINE_MS_DEFAULT = 12000;
const MAX_BODY = 2 * 1024 * 1024;

function createRelay(options) {
  const onlineMs = Number((options && options.onlineMs) || ONLINE_MS_DEFAULT);
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
      online: now - phone.lastSeenMs < onlineMs,
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

  async function dispatch(method, pathname, headers, body) {
    const parts = String(pathname || "").split("/").filter(Boolean);
    if (parts[0] !== "v1" || parts[1] !== "phones") {
      return json(404, { ok: false, error: "not found" });
    }
    const code = String((headers && (headers["x-lojo-network"] || headers["X-Lojo-Network"])) || "")
      .trim()
      .toLowerCase();
    if (!code) return json(401, { ok: false, error: "missing network code" });
    const book = room(code);
    const now = Date.now();

    if (method === "GET" && parts.length === 2) {
      const phones = [...book.phones.values()].map((phone) => publicPhone(phone, now));
      phones.sort((a, b) => a.name.localeCompare(b.name));
      return json(200, { phones });
    }

    if (method === "POST" && parts.length === 2) {
      const parsed = parseJSON(body);
      const id = String(parsed.id || "");
      const name = String(parsed.name || "").trim();
      if (!id || !name) return json(400, { ok: false, error: "id and name are required" });
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
      phone.batteryPercent = numberOrNull(parsed.batteryPercent);
      phone.charging = !!parsed.charging;
      phone.lastSeenMs = now;
      phone.mode = "remote-controller";
      if (Array.isArray(parsed.shortcuts)) phone.shortcuts = sanitizeShortcuts(parsed.shortcuts);
      if (!existing) {
        phone.playback = null;
        phone.music = [];
        phone.lastError = null;
        if (Array.isArray(parsed.schedules) && parsed.schedules.length) {
          phone.schedules = parsed.schedules;
          phone.scheduleRevision = 1;
        }
        book.phones.set(id, phone);
      }
      return json(200, { phone: publicPhone(phone, now) });
    }

    const id = parts[2];
    const phone = id ? book.phones.get(id) : null;
    if (!phone) return json(404, { ok: false, error: "phone not registered" });
    const action = parts[3] || "";

    if (method === "GET" && parts.length === 3) {
      return json(200, { phone: publicPhone(phone, now) });
    }

    if (method === "POST" && action === "heartbeat" && parts.length === 4) {
      const parsed = parseJSON(body);
      phone.lastSeenMs = now;
      if ("batteryPercent" in parsed) phone.batteryPercent = numberOrNull(parsed.batteryPercent);
      if ("charging" in parsed) phone.charging = !!parsed.charging;
      if ("playback" in parsed) phone.playback = parsed.playback;
      if ("music" in parsed) phone.music = Array.isArray(parsed.music) ? parsed.music : [];
      if (Array.isArray(parsed.shortcuts)) phone.shortcuts = sanitizeShortcuts(parsed.shortcuts);
      if ("lastError" in parsed) phone.lastError = parsed.lastError ? String(parsed.lastError) : null;
      const ack = new Set(Array.isArray(parsed.ack) ? parsed.ack.map(String) : []);
      if (ack.size) phone.commands = phone.commands.filter((command) => !ack.has(command.id));
      return json(200, {
        commands: phone.commands,
        schedules: phone.schedules,
        scheduleRevision: phone.scheduleRevision,
      });
    }

    if (method === "POST" && action === "commands" && parts.length === 4) {
      const parsed = parseJSON(body);
      const kind = String(parsed.kind || "");
      if (!["play", "stop", "setVolume", "setSleep", "runShortcut"].includes(kind)) {
        return json(400, { ok: false, error: "unknown command" });
      }
      if (kind === "runShortcut" && !String(parsed.shortcutName || "").trim()) {
        return json(400, { ok: false, error: "shortcut name is required" });
      }
      phone.commandSeq += 1;
      const command = {
        id: "c" + phone.commandSeq,
        seq: phone.commandSeq,
        kind,
        soundID: parsed.soundID ? String(parsed.soundID) : null,
        volume: typeof parsed.volume === "number" ? parsed.volume : null,
        sleepMinutes: Number.isInteger(parsed.sleepMinutes) ? parsed.sleepMinutes : null,
        shortcutName: parsed.shortcutName ? String(parsed.shortcutName).trim() : null,
      };
      phone.commands.push(command);
      return json(200, { command });
    }

    if (action === "schedules" && parts.length === 4) {
      if (method === "GET") {
        return json(200, { schedules: phone.schedules, scheduleRevision: phone.scheduleRevision });
      }
      if (method === "PUT") {
        const parsed = parseJSON(body);
        if (!Array.isArray(parsed.schedules)) return json(400, { ok: false, error: "schedules must be a list" });
        phone.schedules = parsed.schedules;
        phone.scheduleRevision += 1;
        return json(200, { schedules: phone.schedules, scheduleRevision: phone.scheduleRevision });
      }
    }

    if (action === "screen" && parts.length === 4) {
      if (method === "POST") {
        const frame = Buffer.isBuffer(body) ? body : Buffer.from(body || []);
        if (!frame.length) return json(400, { ok: false, error: "empty frame" });
        phone.screen = frame;
        phone.lastSeenMs = now;
        return json(200, { ok: true, bytes: frame.length });
      }
      if (method === "GET") {
        if (!phone.screen) return { status: 204, body: Buffer.alloc(0), type: "application/octet-stream" };
        return { status: 200, body: phone.screen, type: "image/jpeg" };
      }
    }

    return json(404, { ok: false, error: "not found" });
  }

  return { rooms, dispatch, onlineMs };
}

function json(status, value) {
  return {
    status,
    body: Buffer.from(JSON.stringify(value)),
    type: "application/json; charset=utf-8",
  };
}

function parseJSON(body) {
  const text = Buffer.isBuffer(body) ? body.toString("utf8") : String(body || "");
  if (!text) return {};
  return JSON.parse(text);
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

function readRaw(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        const error = new Error("body too large");
        error.status = 413;
        reject(error);
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

module.exports = { createRelay, readRaw, MAX_BODY };
