"use strict";

// Local socket.io 2.5.1 hub. A sidecar that does not send x-gpio-token is rejected.
// Credentials are random per run and must never be printed.

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const test = require("node:test");
const socketIo = require("socket.io");
const socketIoPackage = require("socket.io/package.json");
const clientPackage = require("socket.io-client/package.json");

const sidecarDir = path.resolve(__dirname, "..");
const serverJs = path.join(sidecarDir, "server.js");

test("dependencies stay on socket.io 2.x", () => {
  assert.equal(socketIoPackage.version, "2.5.1");
  assert.match(clientPackage.version, /^2\./);
});

function secret() {
  return crypto.randomBytes(18).toString("hex");
}

function classify(headers, name, expected) {
  if (!Object.prototype.hasOwnProperty.call(headers, name)) return "absent";
  const value = headers[name];
  if (value === "") return "empty";
  if (expected && value === expected) return "match";
  return "other";
}

function startHub({ transport, gpio, legacy, requireGpio }) {
  const server = http.createServer();
  const io = socketIo(server, { transports: [transport], allowUpgrades: false });
  const handshakes = [];
  let connections = 0;
  io.use((socket, next) => {
    const headers = (socket.handshake && socket.handshake.headers) || {};
    handshakes.push({
      transport: socket.conn && socket.conn.transport ? socket.conn.transport.name : "",
      gpio: classify(headers, "x-gpio-token", gpio),
      legacy: classify(headers, "x-lojo-legacy-token", legacy),
    });
    if (requireGpio && headers["x-gpio-token"] !== gpio) {
      next(new Error("unauthorized"));
      return;
    }
    next();
  });
  io.on("connection", () => {
    connections += 1;
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      resolve({
        url: "http://127.0.0.1:" + server.address().port,
        handshakes,
        connections: () => connections,
        close() {
          return new Promise((done) => {
            io.close();
            server.close(() => done());
          });
        },
      });
    });
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function sidecarEnv(home, port, hubUrl, options) {
  const env = {
    PATH: process.env.PATH || "",
    HOME: home,
    TMPDIR: home,
    BIND: "127.0.0.1",
    PORT: String(port),
    PUBNODE_URL: hubUrl,
    STATE_DIR: path.join(home, "state"),
    TLS_DIR: path.join(home, "tls"),
    HUB_TRANSPORTS: options.transport,
    NODE_ENV: "test",
  };
  if (options.emptyTokens) {
    env.GPIO_SOCKET_TOKEN = "";
    env.LEGACY_SOCKET_TOKEN = "";
  }
  if (options.sendGpio) env.GPIO_SOCKET_TOKEN = options.gpio;
  if (options.sendLegacy) env.LEGACY_SOCKET_TOKEN = options.legacy;
  return env;
}

function startSidecar(env) {
  const child = spawn(process.execPath, [serverJs], {
    cwd: sidecarDir,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  child.stdout.on("data", (chunk) => {
    log += chunk;
  });
  child.stderr.on("data", (chunk) => {
    log += chunk;
  });
  return {
    log: () => log,
    stop() {
      return new Promise((resolve) => {
        if (child.exitCode != null || child.signalCode != null) {
          resolve();
          return;
        }
        const timer = setTimeout(() => child.kill("SIGKILL"), 1500);
        child.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
        child.kill("SIGTERM");
      });
    },
  };
}

function getJson(port, pathname) {
  return new Promise((resolve, reject) => {
    const req = http.get(
      { hostname: "127.0.0.1", port, path: pathname, timeout: 1000 },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try {
            json = JSON.parse(body);
          } catch (err) {
            json = null;
          }
          resolve({ status: res.statusCode, body, json });
        });
      }
    );
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("status request timed out")));
  });
}

async function waitUntil(fn, timeoutMs) {
  const start = Date.now();
  let last = "condition not met";
  while (Date.now() - start < timeoutMs) {
    try {
      if (await fn()) return;
    } catch (err) {
      last = err && err.message ? err.message : "condition not met";
    }
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
  throw new Error(last);
}

async function withSidecar(options, check) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ranch-hub-auth-"));
  const hub = await startHub(options);
  const port = await freePort();
  const sidecar = startSidecar(sidecarEnv(home, port, hub.url, options));
  try {
    await check({ hub, sidecar, port });
  } finally {
    await sidecar.stop();
    await hub.close();
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function assertHands(handshakes, transport, gpio, legacy) {
  assert.ok(handshakes.length > 0, "hub saw no handshake");
  handshakes.forEach((row) => {
    assert.equal(row.transport, transport, "handshake transport");
    assert.equal(row.gpio, gpio, "x-gpio-token");
    assert.equal(row.legacy, legacy, "x-lojo-legacy-token");
  });
}

function assertNoSecrets(text, secrets, label) {
  secrets.forEach((secretValue) => {
    if (!secretValue) return;
    assert.equal(String(text).includes(secretValue), false, label);
  });
}

async function readStatus(port) {
  const health = await getJson(port, "/health");
  const network = await getJson(port, "/v1/network");
  assert.equal(health.status, 200);
  assert.equal(network.status, 200);
  assert.equal(health.json && health.json.service, "ranch-field-api");
  assert.ok(network.json && network.json.hub, "missing hub status");
  return { health, network };
}

for (const transport of ["websocket", "polling"]) {
  test(transport + " hub rejects the sidecar when GPIO_SOCKET_TOKEN is unset", async () => {
    const gpio = secret();
    await withSidecar({ transport, gpio, requireGpio: true }, async ({ hub, port }) => {
      await waitUntil(async () => {
        const { network } = await readStatus(port);
        return hub.handshakes.length > 0 && network.json.hub.lastError === "unauthorized";
      }, 5000);
      assertHands(hub.handshakes, transport, "absent", "absent");
      assert.equal(hub.connections(), 0, "hub accepted a sidecar that sent no token");
      const { health, network } = await readStatus(port);
      assert.equal(health.json.hubAuth, "none");
      assert.equal(network.json.hubAuth, "none");
      assert.equal(network.json.hub.connected, false);
      assert.equal(network.json.hub.lastError, "unauthorized");
    });
  });

  test(transport + " hub accepts the sidecar when GPIO_SOCKET_TOKEN is set", async () => {
    const gpio = secret();
    await withSidecar(
      { transport, gpio, requireGpio: true, sendGpio: true },
      async ({ hub, sidecar, port }) => {
        await waitUntil(async () => {
          if (hub.connections() < 1) return false;
          const health = await getJson(port, "/health");
          return health.status === 200 && health.json && health.json.pubnodeConnected === true;
        }, 5000);
        assertHands(hub.handshakes, transport, "match", "absent");
        const { health, network } = await readStatus(port);
        assert.equal(health.json.hubAuth, "configured");
        assert.equal(network.json.hubAuth, "configured");
        assert.equal(network.json.hub.connected, true);
        assert.equal(network.json.hub.lastError, null);
        assert.equal(health.json.pubnodeConnected, true);
        assertNoSecrets(health.body, [gpio], "/health contains a credential");
        assertNoSecrets(network.body, [gpio], "/v1/network contains a credential");
        assertNoSecrets(sidecar.log(), [gpio], "sidecar log contains a credential");
      }
    );
  });

  test(transport + " sends no auth header when the variables are unset", async () => {
    await withSidecar({ transport }, async ({ hub, port }) => {
      await waitUntil(async () => {
        if (hub.connections() < 1) return false;
        const health = await getJson(port, "/health");
        return health.status === 200;
      }, 5000);
      assertHands(hub.handshakes, transport, "absent", "absent");
      const { health, network } = await readStatus(port);
      assert.equal(health.json.hubAuth, "none");
      assert.equal(network.json.hubAuth, "none");
    });
  });
}

test("empty token variables do not send headers", async () => {
  await withSidecar({ transport: "polling", emptyTokens: true }, async ({ hub, port }) => {
    await waitUntil(async () => {
      if (hub.connections() < 1) return false;
      const health = await getJson(port, "/health");
      return health.status === 200;
    }, 5000);
    assertHands(hub.handshakes, "polling", "absent", "absent");
    const { health } = await readStatus(port);
    assert.equal(health.json.hubAuth, "none");
  });
});

test("LEGACY_SOCKET_TOKEN is sent alone and stays out of /health and logs", async () => {
  const legacy = secret();
  await withSidecar(
    { transport: "websocket", legacy, sendLegacy: true },
    async ({ hub, sidecar, port }) => {
      await waitUntil(async () => {
        if (hub.connections() < 1) return false;
        const health = await getJson(port, "/health");
        return health.status === 200 && health.json && health.json.hubAuth === "configured";
      }, 5000);
      assertHands(hub.handshakes, "websocket", "absent", "match");
      const { health, network } = await readStatus(port);
      assert.equal(health.json.hubAuth, "configured");
      assert.equal(network.json.hubAuth, "configured");
      assertNoSecrets(health.body, [legacy], "/health contains a credential");
      assertNoSecrets(network.body, [legacy], "/v1/network contains a credential");
      assertNoSecrets(sidecar.log(), [legacy], "sidecar log contains a credential");
    }
  );
});

test("polling sends both handshake headers and neither value appears in status or logs", async () => {
  const gpio = secret();
  const legacy = secret();
  await withSidecar(
    { transport: "polling", gpio, legacy, requireGpio: true, sendGpio: true, sendLegacy: true },
    async ({ hub, sidecar, port }) => {
      await waitUntil(async () => {
        if (hub.connections() < 1) return false;
        const health = await getJson(port, "/health");
        return health.status === 200 && health.json && health.json.pubnodeConnected === true;
      }, 5000);
      assertHands(hub.handshakes, "polling", "match", "match");
      const { health, network } = await readStatus(port);
      assert.equal(health.json.hubAuth, "configured");
      assert.equal(network.json.hub.lastError, null);
      const secrets = [gpio, legacy];
      assertNoSecrets(health.body, secrets, "/health contains a credential");
      assertNoSecrets(network.body, secrets, "/v1/network contains a credential");
      assertNoSecrets(sidecar.log(), secrets, "sidecar log contains a credential");
    }
  );
});
