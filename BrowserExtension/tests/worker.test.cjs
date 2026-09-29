const { test } = require("node:test");
const assert = require("node:assert/strict");
const { runInNewContext } = require("node:vm");
const { readFileSync } = require("node:fs");
const { webcrypto } = require("node:crypto");

const code = readFileSync(require.resolve("../worker.js"), "utf8");
const URL_ON_TAB = "https://claude.ai/chat";
const HASH_A = "a".repeat(64);
const HASH_B = "b".repeat(64);
const HASH_ORG = "c".repeat(64);

function harness() {
  let stored;
  const native = [];
  const acks = [];
  const alarms = [];
  const tabs = [{ id: 7, url: URL_ON_TAB, active: true }];
  const listener = {};
  const chrome = {
    runtime: {
      id: "extension-id",
      onMessage: { addListener: callback => { listener.message = callback; } },
      onStartup: { addListener: callback => { listener.startup = callback; } },
      sendNativeMessage: async (host, envelope) => {
        assert.equal(host, "co.ishikawa.quotatempo");
        native.push(envelope);
        return acks.length ? acks.shift() : { ok: true };
      }
    },
    storage: { local: {
      get: async () => ({ bridgeState: stored }),
      set: async value => { stored = value.bridgeState; }
    } },
    alarms: {
      create: async (name, options) => { alarms.push({ name, options }); },
      clear: async () => true,
      onAlarm: { addListener: callback => { listener.alarm = callback; } }
    },
    tabs: {
      query: async options => options.active ? tabs.filter(tab => tab.active) : tabs,
      get: async id => {
        const tab = tabs.find(candidate => candidate.id === id);
        if (!tab) throw new Error("missing tab");
        return tab;
      },
      sendMessage: async () => ({ accepted: true }),
      onUpdated: { addListener: callback => { listener.updated = callback; } },
      onRemoved: { addListener: callback => { listener.removed = callback; } }
    },
    scripting: { executeScript: async () => {} }
  };
  runInNewContext(code, { chrome, crypto: webcrypto, URL, Date, Promise, Number, Object, Set });
  const popup = { id: "extension-id" };
  const content = id => ({
    id: "extension-id", frameId: 0, url: URL_ON_TAB, origin: "https://claude.ai",
    tab: { id, url: URL_ON_TAB }
  });
  const message = (body, sender = popup) => new Promise(resolve => {
    listener.message(body, sender, resolve);
  });
  const result = accountFingerprint => ({
    status: "ok", accountFingerprint, organizationFingerprint: HASH_ORG,
    principalFingerprint: accountFingerprint,
    weekly: { remainingPercent: 75, resetAt: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000).toISOString() },
    fiveHour: null
  });
  const observe = (resultValue, id = 7, observedAt = new Date().toISOString()) => message({
    type: "observation", requestID: stored.inFlight.requestID, observedAt, result: resultValue
  }, content(id));
  const flush = () => message({ type: "state" });
  const fireDueAlarm = () => {
    stored.nextAt = Date.now();
    listener.alarm({ name: "quotaTempoPoll" });
  };
  return { native, acks, alarms, tabs, listener, message, content, result, observe, flush, fireDueAlarm,
    get stored() { return stored; } };
}

test("Connect ACK precedes usage; account switch revokes and reconnect creates a new generation", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  assert.equal(h.native[0].status, "connected");
  assert.equal(h.native[0].sequence, 0);
  assert.equal(h.native[0].weekly, null);
  assert.equal(h.stored.pin, null);
  await h.observe(h.result(HASH_A));
  assert.equal(h.native[1].status, "ok");
  assert.equal(h.native[1].sequence, 1);
  assert.equal(h.native[1].connectionID, h.native[0].connectionID);
  assert.equal(h.stored.pin.accountFingerprint, HASH_A);
  h.fireDueAlarm();
  await h.flush();
  await h.observe(h.result(HASH_B));
  assert.equal(h.native[2].status, "accountChanged");
  assert.equal(h.native[2].sequence, 2);
  assert.equal(h.native[2].weekly, null);
  assert.equal(h.stored.blocked, true);
  await h.message({ type: "reconnect" });
  assert.equal(h.native[3].status, "disconnected");
  assert.equal(h.native[3].sequence, 3);
  assert.equal(h.native[4].status, "connected");
  assert.equal(h.native[4].sequence, 0);
  assert.notEqual(h.native[4].connectionID, h.native[0].connectionID);
  assert.equal(h.native[4].profileID, h.native[0].profileID);
  await h.observe(h.result(HASH_B));
  assert.equal(h.stored.pin.accountFingerprint, HASH_B);
});

test("diagnostics stay in the extension and never reach the native host", async () => {
  const h = harness();
  assert.equal((await h.flush()).workerVersion, require("../manifest.json").version);
  await h.message({ type: "connect" });
  await h.observe({ status: "unavailable", diagnostic: "accountShape" });
  assert.equal(h.stored.lastFailureStage, "accountShape");
  assert.equal(h.native[1].status, "unavailable");
  assert.equal(Object.hasOwn(h.native[1], "diagnostic"), false);
  assert.equal(Object.hasOwn(h.native[1], "workerVersion"), false);
  assert.equal((await h.flush()).lastFailureStage, "accountShape");
  h.fireDueAlarm();
  await h.flush();
  await h.observe(h.result(HASH_A));
  assert.equal(h.stored.lastFailureStage, null);
});

test("connected ACK failure sends no observation and retries exact envelope on explicit Connect", async () => {
  const h = harness();
  h.acks.push({ ok: false, error: "unavailable" });
  await h.message({ type: "connect" });
  assert.equal(h.stored.enabled, false);
  assert.equal(h.stored.pendingConnect, true);
  assert.equal(h.stored.inFlight, null);
  await h.message({ type: "connect" });
  assert.deepEqual(h.native[1], h.native[0]);
  assert.equal(h.stored.enabled, true);
  assert.equal(h.stored.inFlight !== null, true);
});

test("unconfirmed disconnect is retried exactly before a fresh Connect", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  h.acks.push({ ok: false, error: "unavailable" });
  await h.message({ type: "disconnect" });
  assert.equal(h.stored.enabled, false);
  assert.equal(h.stored.pendingDisconnect, true);
  assert.equal(h.stored.pin.accountFingerprint, HASH_A);
  const oldID = h.stored.connectionID;
  await h.message({ type: "connect" });
  assert.deepEqual(h.native[3], h.native[2]);
  assert.equal(h.native[4].status, "connected");
  assert.notEqual(h.native[4].connectionID, oldID);
  assert.equal(h.stored.pendingDisconnect, false);
});

test("revocation ACK failure retries exact value-free envelope before stopping", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  h.fireDueAlarm();
  await h.flush();
  h.acks.push({ ok: false, error: "unavailable" });
  await h.observe(h.result(HASH_B));
  assert.equal(h.stored.blocked, true);
  assert.equal(h.stored.pendingRevocation.message.status, "accountChanged");
  assert.equal(h.stored.pendingRevocation.message.weekly, null);
  assert.equal(h.stored.nextAt !== null, true);
  h.fireDueAlarm();
  await h.flush();
  assert.deepEqual(h.native[3], h.native[2]);
  assert.equal(h.stored.pendingRevocation, null);
  assert.equal(h.stored.nextAt, null);
  assert.equal(h.stored.sequence, 2);
});

test("expired or forged completion times cannot deliver late usage", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  const oldID = h.stored.inFlight.requestID;
  h.stored.inFlight.expiresAt = Date.now() - 1;
  const old = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const rejected = await h.message({ type: "observation", requestID: oldID,
    observedAt: old, result: h.result(HASH_A) }, h.content(7));
  assert.equal(rejected.accepted, false);
  assert.equal(h.native.length, 1);
  h.fireDueAlarm();
  await h.flush();
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.stored.lastFailureStage, "responseTimeout");
  assert.equal(h.native[1].status, "unavailable");
  assert.equal(h.stored.failureCount, 1);
  assert.ok(h.stored.nextAt >= Date.now() + 299_000);
  h.fireDueAlarm();
  await h.flush();
  const freshID = h.stored.inFlight.requestID;
  assert.notEqual(freshID, oldID);
  assert.equal((await h.message({ type: "observation", requestID: oldID,
    observedAt: new Date().toISOString(), result: h.result(HASH_A) }, h.content(7))).accepted, false);
  await new Promise(resolve => setTimeout(resolve, 10));
  const completedAt = new Date(Date.now() - 1).toISOString();
  await h.observe(h.result(HASH_A), 7, completedAt);
  assert.equal(h.native[2].observedAt, completedAt);
});

test("worker rejects other tabs, frames, and origins before native delivery", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  const requestID = h.stored.inFlight.requestID;
  for (const sender of [
    { ...h.content(7), frameId: 1 },
    { ...h.content(7), tab: { id: 9, url: URL_ON_TAB } },
    { ...h.content(7), url: "https://other.example/" }
  ]) {
    assert.equal((await h.message({ type: "observation", requestID,
      observedAt: new Date().toISOString(), result: h.result(HASH_A) }, sender)).accepted, false);
  }
  assert.equal(h.native.length, 1);
  await h.observe(h.result(HASH_A));
  assert.equal(h.native.length, 2);
});

test("missing content replies back off to a bounded hour without retaining an in-flight request", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  for (const minutes of [5, 10, 20, 40, 60, 60]) {
    h.stored.inFlight.expiresAt = Date.now() - 1;
    const before = Date.now();
    h.fireDueAlarm();
    await h.flush();
    assert.equal(h.stored.inFlight, null);
    assert.equal(h.stored.lastFailureStage, "responseTimeout");
    assert.equal(h.native.at(-1).status, "unavailable");
    assert.equal(h.native.at(-1).weekly, null);
    assert.ok(h.stored.nextAt >= before + minutes * 60_000);
    assert.ok(h.stored.nextAt <= Date.now() + minutes * 60_000);
    h.fireDueAlarm();
    await h.flush();
  }
});

test("startup preserves the generation and pin and waits for an existing tab", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  const generation = h.stored.connectionID;
  h.tabs.splice(0);
  h.listener.startup();
  await h.flush();
  assert.equal(h.stored.enabled, true);
  assert.equal(h.stored.pin.accountFingerprint, HASH_A);
  assert.equal(h.stored.connectionID, generation);
  assert.equal(h.stored.status, "waitingForTab");
  assert.equal(h.native.length, 2);
  h.tabs.push({ id: 8, url: URL_ON_TAB, active: true });
  h.listener.updated(8, { status: "complete" }, h.tabs[0]);
  await h.flush();
  assert.equal(h.stored.inFlight.tabID, 8);
  await h.observe(h.result(HASH_A), 8);
  assert.equal(h.native[2].connectionID, generation);
  assert.equal(h.native[2].sequence, 2);
  assert.equal(h.stored.recovering, false);
});

test("recovery tab events cannot skip timeout diagnosis or retry backoff", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  h.listener.startup();
  await h.flush();
  h.stored.inFlight.expiresAt = Date.now() - 1;
  h.listener.updated(7, { status: "complete" }, h.tabs[0]);
  await h.flush();
  const deadline = h.stored.nextAt;
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.stored.lastFailureStage, "responseTimeout");
  assert.equal(h.stored.failureCount, 1);
  assert.equal(h.native.at(-1).status, "unavailable");
  h.listener.updated(7, { status: "complete" }, h.tabs[0]);
  h.listener.alarm({ name: "quotaTempoPoll" });
  await h.flush();
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.stored.nextAt, deadline);
  assert.equal(h.stored.failureCount, 1);
  h.fireDueAlarm();
  await h.flush();
  assert.ok(h.stored.inFlight);
});

test("browser startup restores a pending failure alarm without bypassing its deadline", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  h.fireDueAlarm();
  await h.flush();
  await h.observe({ status: "rateLimited" });
  const deadline = h.stored.nextAt;
  const alarmCount = h.alarms.length;
  h.listener.startup();
  await h.flush();
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.stored.recovering, true);
  assert.equal(h.stored.nextAt, deadline);
  assert.equal(h.alarms.length, alarmCount + 1);
  assert.equal(h.alarms.at(-1).options.when, deadline);
  h.listener.updated(7, { status: "complete" }, h.tabs[0]);
  await h.flush();
  assert.equal(h.stored.inFlight, null);
  h.fireDueAlarm();
  await h.flush();
  assert.ok(h.stored.inFlight);
});

test("old request replies cannot reactivate a disconnected generation", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  const oldRequestID = h.stored.inFlight.requestID;
  await h.message({ type: "disconnect" });
  assert.equal((await h.message({ type: "observation", requestID: oldRequestID,
    observedAt: new Date().toISOString(), result: h.result(HASH_A) }, h.content(7))).accepted, false);
  assert.deepEqual(h.native.map(item => item.status), ["connected", "disconnected"]);
  await h.message({ type: "connect" });
  assert.equal((await h.message({ type: "observation", requestID: oldRequestID,
    observedAt: new Date().toISOString(), result: h.result(HASH_A) }, h.content(7))).accepted, false);
  assert.equal(h.native[2].status, "connected");
  assert.notEqual(h.native[2].connectionID, h.native[0].connectionID);
});

test("restored tab with a different account revokes without replacing the pin", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  h.listener.startup();
  await h.flush();
  await h.observe(h.result(HASH_B));
  assert.equal(h.native[2].status, "accountChanged");
  assert.equal(h.native[2].weekly, null);
  assert.equal(h.stored.pin.accountFingerprint, HASH_A);
  assert.equal(h.stored.recovering, true);
  assert.equal(h.stored.status, "waitingForAccount");
});

test("429 backs off at least 15 minutes and Disconnect sends a value-free envelope", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe({ status: "rateLimited" });
  assert.equal(h.native[1].status, "rateLimited");
  assert.equal(h.stored.nextAt - Date.now() >= 15 * 60 * 1000 - 1000, true);
  await h.message({ type: "disconnect" });
  assert.equal(h.stored.enabled, false);
  assert.equal(h.stored.pin, null);
  assert.equal(h.stored.nextAt, null);
  assert.equal(h.native[2].status, "disconnected");
  assert.equal(h.native[2].weekly, null);
});
