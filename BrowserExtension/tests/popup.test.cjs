const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { runInNewContext } = require("node:vm");
const manifest = require("../manifest.json");
const code = readFileSync(require.resolve("../popup.js"), "utf8");

async function harness(reply) {
  const nodes = Object.fromEntries([
    "version", "status", "detail", "connect", "reconnect", "disconnect"
  ].map(id => [id, { textContent: "", hidden: false, addEventListener() {} }]));
  let changed;
  const chrome = {
    runtime: { sendMessage: async () => reply },
    storage: { onChanged: { addListener: callback => { changed = callback; } } }
  };
  runInNewContext(code, { chrome, document: { getElementById: id => nodes[id] } });
  await new Promise(resolve => setImmediate(resolve));
  return { nodes, change: value => changed({ bridgeState: { newValue: value } }, "local") };
}

test("popup shows exact popup and worker versions with bounded acquisition stage", async () => {
  const h = await harness({ status: "unavailable", enabled: true,
    workerVersion: manifest.version, lastFailureStage: "usageShape" });
  assert.equal(h.nodes.version.textContent, `Bridge ${manifest.version} / worker ${manifest.version}`);
  assert.equal(h.nodes.detail.textContent, "Acquisition stopped at usageShape.");
  assert.equal(h.nodes.reconnect.hidden, false);
  assert.equal(h.nodes.connect.hidden, true);
  h.change({ status: "ok", enabled: true });
  assert.equal(h.nodes.status.textContent, "Connected");
  assert.equal(h.nodes.detail.textContent, "Observation delivered to QuotaTempo.");
  assert.equal(h.nodes.version.textContent, `Bridge ${manifest.version} / worker ${manifest.version}`);
});

test("old or unknown worker gives an explicit reload instruction", async () => {
  for (const workerVersion of [undefined, "0.1.0"]) {
    const h = await harness({ status: "unavailable", enabled: true, workerVersion });
    assert.equal(h.nodes.detail.textContent,
      "Reload QuotaTempo in chrome://extensions, then reopen this popup.");
    assert.equal(h.nodes.version.textContent,
      `Bridge ${manifest.version} / worker ${workerVersion ?? "unknown"}`);
  }
});

test("pending disconnect warning takes precedence over version diagnostics", async () => {
  const h = await harness({ status: "nativeUnavailable", enabled: false, pendingDisconnect: true });
  assert.match(h.nodes.detail.textContent, /^Disconnect is unconfirmed/);
  assert.equal(h.nodes.disconnect.hidden, false);
});
