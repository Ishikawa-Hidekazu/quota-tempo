// Synthetic native-server acceptance; not a live Code or provider test.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import { register } from "../hooks/register.mjs";

const [directory, timeText, action = "measure", publicKey] = process.argv.slice(2);
assert.match(directory, /^\/private\/tmp\/qtc-[0-9a-f-]{36}$/);
assert.match(publicKey, /^[0-9a-f]{64}$/);
const now = Number(timeText);
assert.ok(Number.isFinite(now));
const handlers = new Map();
let requests = 0;
let writes = 0;
register((name, filter, handler) => handlers.set(name, typeof filter === "function" ? filter : handler));
const $ = {
  clock: {
    now: async () => now,
    after: (ms, fn) => {
      const timer = setTimeout(fn, ms);
      return { cancel: () => clearTimeout(timer) };
    },
  },
  command: { register: async () => {} },
  fs: {
    exists: async path => { try { await fs.lstat(path); return true; } catch { return false; } },
    stat: async (path, options) => {
      assert.ok(path === directory || path === `${directory}/probe-grant.json`);
      const stat = await fs.lstat(path);
      return { kind: stat.isDirectory() ? "dir" : "file", size: stat.size,
        isLink: stat.isSymbolicLink(), ...(options?.resolve ? { realPath: await fs.realpath(path) } : {}) };
    },
    read: async path => {
      assert.equal(path, `${directory}/probe-grant.json`);
      return fs.readFile(path, "utf8");
    },
    write: async () => { writes++; throw new Error("unexpected_quota_write"); },
  },
  http: { fetch: (url, init) => new Promise((resolve, reject) => {
    assert.equal(init.socketPath, `${directory}/bridge.sock`);
    assert.equal(init.auth, undefined);
    assert.match(url, /^http:\/\/quotatempo\/(connect|measure|disconnect)$/);
    const envelope = JSON.parse(init.body);
    assert.equal(envelope.schemaVersion, 3);
    assert.deepEqual(Object.keys(envelope).sort(), ["ciphertext", "connectionID", "enc", "requestID", "schemaVersion", "streamID"]);
    assert.equal(init.body.includes('"rateLimits"'), false);
    assert.equal(init.body.includes('"percentUsed"'), false);
    requests++;
    const target = new URL(url);
    const request = http.request({ socketPath: init.socketPath, method: init.method,
      path: target.pathname, headers: { ...init.headers, host: target.hostname,
        "content-length": Buffer.byteLength(init.body) }, timeout: 3000 }, response => {
      let text = "";
      response.on("data", chunk => { text += chunk; if (text.length > 1024) response.destroy(); });
      response.on("end", () => resolve({ status: response.statusCode,
        ok: response.statusCode === 200, headers: response.headers, text }));
      response.on("error", reject);
    });
    request.on("timeout", () => request.destroy(new Error("timeout")));
    request.on("error", reject);
    request.end(init.body);
  }) },
};
await handlers.get("session.start")($, {}, async event => event);
const connected = await handlers.get("command.run")($, { args: `connect ${directory} ${publicKey}` });
assert.match(connected.text, /Comparison-only probe connected/);
await handlers.get("session.measure")($, { rateLimits: [
  { kind: "seven_day", percentUsed: 42, resetsAt: new Date(now + 86400000).toISOString() },
] }, async event => event);
if (action === "disconnect") {
  const disconnected = await handlers.get("command.run")($, { args: "disconnect" });
  assert.match(disconnected.text, /disconnected/);
}
assert.equal(writes, 0);
assert.equal(requests, action === "disconnect" ? 3 : 2);
process.stdout.write(JSON.stringify({ status: "passed", requests, quotaFileWrites: writes }));
