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

function harness({ nativeHandler } = {}) {
  let stored;
  let activeAlarm;
  let now;
  let pause;
  const writes = [];
  const checkpoint = async (point, value) => {
    if (pause?.point !== point || !pause.matches(value)) return;
    const hit = pause.hit;
    pause = undefined;
    hit(structuredClone(value));
    // Leave the old worker suspended forever; reload starts a separate VM/queue.
    await new Promise(() => {});
  };
  class WorkerDate extends Date {
    constructor(...args) { super(...(args.length ? args : [WorkerDate.now()])); }
    static now() { return now ?? Date.now(); }
  }
  const native = [];
  const acks = [];
  const alarms = [];
  const requests = [];
  const scripts = [];
  const tabs = [{ id: 7, url: URL_ON_TAB, active: true }];
  const listener = {};
  const chrome = {
    runtime: {
      id: "extension-id",
      onMessage: { addListener: callback => { listener.message = callback; } },
      onStartup: { addListener: callback => { listener.startup = callback; } },
      sendNativeMessage: async (host, envelope) => {
        assert.equal(host, "co.ishikawa.quotatempo");
        const message = structuredClone(envelope);
        await checkpoint("native.beforeSend", message);
        native.push(message);
        const ack = acks.length ? acks.shift()
          : nativeHandler ? await nativeHandler(message, WorkerDate.now()) : { ok: true };
        await checkpoint("native.afterSend", message);
        await checkpoint("native.afterAck", message);
        return structuredClone(ack);
      }
    },
    storage: { local: {
      get: async () => ({ bridgeState: structuredClone(stored) }),
      set: async value => {
        const snapshot = structuredClone(value.bridgeState);
        await checkpoint("storage.beforeSet", snapshot);
        stored = snapshot;
        writes.push(structuredClone(snapshot));
        await checkpoint("storage.afterSet", snapshot);
      }
    } },
    alarms: {
      get: async name => activeAlarm?.name === name ? activeAlarm : undefined,
      create: async (name, options) => {
        await checkpoint("alarms.beforeCreate", options);
        alarms.push({ name, options });
        activeAlarm = { name, scheduledTime: options.when };
      },
      clear: async () => {
        await checkpoint("alarms.beforeClear", activeAlarm);
        activeAlarm = undefined;
        return true;
      },
      onAlarm: { addListener: callback => { listener.alarm = callback; } }
    },
    tabs: {
      query: async options => options.active ? tabs.filter(tab => tab.active) : tabs,
      get: async id => {
        const tab = tabs.find(candidate => candidate.id === id);
        if (!tab) throw new Error("missing tab");
        return tab;
      },
      sendMessage: async (...args) => { requests.push(args); return { accepted: true }; },
      onUpdated: { addListener: callback => { listener.updated = callback; } },
      onRemoved: { addListener: callback => { listener.removed = callback; } }
    },
    scripting: { executeScript: async options => { scripts.push(options); } }
  };
  const initialize = () => runInNewContext(code, {
    chrome, crypto: webcrypto, URL, Date: WorkerDate, Promise, Number, Object, Set
  });
  initialize();
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
    weekly: { remainingPercent: 75, resetAt: new Date(WorkerDate.now() + 2 * 24 * 60 * 60 * 1000).toISOString() },
    fiveHour: null
  });
  const observe = (resultValue, id = 7, observedAt = new WorkerDate().toISOString()) => message({
    type: "observation", requestID: stored.inFlight.requestID, observedAt, result: resultValue
  }, content(id));
  const flush = () => message({ type: "state" });
  const fireAlarm = () => {
    activeAlarm = undefined;
    listener.alarm({ name: "quotaTempoPoll" });
  };
  const fireDueAlarm = () => {
    now = Math.max(WorkerDate.now(), stored.inFlight?.expiresAt ?? stored.nextAt ?? 0);
    fireAlarm();
  };
  const reload = ({ keepAlarm = false } = {}) => {
    stored = structuredClone(stored);
    if (!keepAlarm) activeAlarm = undefined;
    initialize();
  };
  return { native, acks, alarms, requests, scripts, tabs, listener, message, content, writes,
    result, observe, flush, fireAlarm, fireDueAlarm, reload,
    pauseNext: (point, matches = () => true) => {
      assert.equal(pause, undefined);
      return new Promise(hit => { pause = { point, matches, hit }; });
    },
    editStored: edit => {
      const snapshot = structuredClone(stored);
      edit(snapshot);
      stored = structuredClone(snapshot);
    },
    advanceTo: timestamp => { now = timestamp; },
    get now() { return WorkerDate.now(); },
    get alarm() { return activeAlarm; },
    get stored() { return structuredClone(stored); } };
}

async function connectedHarness() {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  return h;
}

async function revokingHarness(recovering = false, pending = false) {
  const h = await connectedHarness();
  h.advanceTo(h.stored.nextAt);
  if (recovering) h.listener.startup();
  else h.fireAlarm();
  await h.flush();
  if (pending) {
    h.acks.push({ ok: false, error: "unavailable" });
    await h.observe(h.result(HASH_B));
  }
  return h;
}

async function assertRestoredRevocation(h, recovering, original) {
  const persisted = h.stored;
  const nativeCount = h.native.length;
  h.reload();
  await h.flush();
  assert.deepEqual(h.stored, persisted);
  assert.equal(h.native.length, nativeCount);
  if (persisted.pendingRevocation) {
    assert.equal(persisted.inFlight, null);
    assert.equal(persisted.blocked, !recovering);
    const envelope = persisted.pendingRevocation.message;
    h.listener.updated(7, { status: "complete" }, h.tabs[0]);
    h.fireAlarm();
    await h.flush();
    assert.equal(h.native.length, nativeCount);
    assert.equal(h.stored.nextAt, persisted.nextAt);
    h.advanceTo(persisted.nextAt);
    h.fireAlarm();
    await h.flush();
    assert.deepEqual(h.native.at(-1), envelope);
  }
  assert.equal(h.stored.pendingRevocation, null);
  assert.equal(h.stored.connectionID, original.connectionID);
  assert.deepEqual(h.stored.pin, original.pin);
  assert.equal(h.stored.blocked, !recovering);
  assert.equal((await h.message({ type: "observation", requestID: original.inFlight.requestID,
    observedAt: new Date(original.inFlight.expiresAt - 60_000).toISOString(),
    result: h.result(HASH_B) }, h.content(7))).accepted, false);
  if (!recovering) {
    assert.equal(h.stored.inFlight, null);
    assert.equal(h.stored.status, "accountChanged");
    assert.equal(h.stored.nextAt, null);
    const stoppedAt = h.native.length;
    h.fireAlarm();
    h.listener.updated(7, { status: "complete" }, h.tabs[0]);
    await h.flush();
    assert.equal(h.native.length, stoppedAt);
    assert.equal(h.requests.length, 2);
    assert.equal(h.alarm, undefined);
  } else {
    assert.equal(h.stored.recovering, true);
    if (!h.stored.inFlight) {
      assert.equal(h.stored.status, "waitingForAccount");
      const deadline = h.stored.nextAt;
      const requestCount = h.requests.length;
      if (Number.isFinite(deadline)) {
        h.fireAlarm();
        h.listener.updated(7, { status: "complete" }, h.tabs[0]);
        await h.flush();
        assert.equal(h.requests.length, requestCount);
        assert.equal(h.stored.nextAt, deadline);
      }
      h.advanceTo(deadline ?? h.alarm.scheduledTime);
      h.fireAlarm();
      await h.flush();
    }
    await h.observe(h.result(HASH_A));
    assert.equal(h.stored.recovering, false);
    assert.equal(h.native.at(-1).status, "ok");
    assert.equal(h.native.at(-1).connectionID, original.connectionID);
    assert.deepEqual(h.stored.pin, original.pin);
  }
}

test("storage and native messages are persisted by value", async () => {
  const h = await connectedHarness();
  const snapshot = h.stored;
  snapshot.pin.accountFingerprint = HASH_B;
  assert.equal(h.stored.pin.accountFingerprint, HASH_A);
  const envelope = structuredClone(h.native[1]);
  await h.message({ type: "reconnect" });
  assert.deepEqual(h.native[1], envelope);
  assert.equal(h.writes.some(value => value.pin?.accountFingerprint === HASH_A), true);
});

test("optional reset crossed between parsing and delivery preserves the exact weekly window", async t => {
  const { parseUsage } = require("../protocol.js");
  const capturedAt = Date.parse("2026-09-30T00:00:00.000Z");
  for (const delay of [499, 500, 501, 23_000]) {
    await t.test(`delivery after ${delay}ms`, async () => {
      const h = harness();
      h.advanceTo(capturedAt);
      await h.message({ type: "connect" });
      const windows = parseUsage({
        seven_day: { utilization: 27, resets_at: new Date(capturedAt + 2 * 86_400_000).toISOString() },
        five_hour: { utilization: 80, resets_at: new Date(capturedAt + 500).toISOString() }
      }, capturedAt);
      assert.notEqual(windows.fiveHour, null);
      const result = { ...h.result(HASH_A), ...windows };
      const before = structuredClone(result);
      h.advanceTo(capturedAt + delay);
      await h.observe(result, 7, new Date(capturedAt).toISOString());
      const message = h.native.at(-1);
      assert.equal(message.status, "ok");
      assert.equal(message.observedAt, new Date(capturedAt).toISOString());
      assert.deepEqual(message.weekly, windows.weekly);
      assert.deepEqual(message.fiveHour, delay < 500 ? windows.fiveHour : null);
      assert.deepEqual(result, before);
      assert.equal(h.stored.failureCount, 0);
      assert.equal(h.stored.nextAt, capturedAt + delay + 300_000);
      assert.equal(h.stored.pin.accountFingerprint, HASH_A);
    });
  }
});

test("optional omission never bypasses normalized schema, calendar or future bounds", async t => {
  const now = Date.parse("2026-09-30T00:00:00.000Z");
  const elapsed = { remainingPercent: 20, resetAt: new Date(now - 23_000).toISOString() };
  const invalid = [
    ["missing window", undefined], ["array window", []], ["string window", "expired"],
    ["missing percent", { resetAt: elapsed.resetAt }],
    ["missing reset", { remainingPercent: 20 }],
    ...[NaN, Infinity, -1, 101, "20", null].map((value, i) => [`invalid percent ${i}`, { ...elapsed, remainingPercent: value }]),
    ...[
      null, now - 23_000, "invalid", "2026-02-30T00:00:00.000Z",
      "2026-09-29T24:00:00.000Z", "2026-09-29T23:60:00.000Z",
      "2026-09-29T23:59:60.000Z", "2026-09-29T23:59:37Z",
      "2026-09-29T23:59:37.000000Z", "2026-09-30T08:59:37.000+09:00",
      "2026-09-29T23:59:37.000Z\n", new Date(now + 6 * 3_600_000 + 1).toISOString()
    ].map((value, i) => [`invalid reset ${i}`, { ...elapsed, resetAt: value }])
  ];
  for (const [label, fiveHour] of invalid) {
    await t.test(label, async () => {
      const h = harness();
      h.advanceTo(now);
      await h.message({ type: "connect" });
      await h.observe({ ...h.result(HASH_A), fiveHour });
      assert.equal(h.native.at(-1).status, "unavailable");
      assert.equal(h.native.at(-1).weekly, null);
      assert.equal(h.native.at(-1).fiveHour, null);
      assert.equal(h.stored.lastFailureStage, "workerValidation");
      assert.equal(h.stored.pin, null);
      assert.equal(h.stored.failureCount, 1);
    });
  }
  for (const remainingPercent of [0, 100]) {
    for (const offset of [-23_000, 0, 1, 6 * 3_600_000]) {
      await t.test(`valid percent ${remainingPercent}, reset offset ${offset}`, async () => {
        const h = harness();
        h.advanceTo(now);
        await h.message({ type: "connect" });
        const fiveHour = { remainingPercent, resetAt: new Date(now + offset).toISOString() };
        await h.observe({ ...h.result(HASH_A), fiveHour });
        assert.equal(h.native.at(-1).status, "ok");
        assert.deepEqual(h.native.at(-1).fiveHour, offset > 0 ? fiveHour : null);
      });
    }
  }
});

test("required weekly expiry during delivery still rejects the entire observation", async () => {
  const h = harness();
  const capturedAt = Date.parse("2026-09-30T00:00:00.000Z");
  h.advanceTo(capturedAt);
  await h.message({ type: "connect" });
  const result = {
    ...h.result(HASH_A),
    weekly: { remainingPercent: 73, resetAt: new Date(capturedAt + 500).toISOString() },
    fiveHour: { remainingPercent: 20, resetAt: new Date(capturedAt + 100).toISOString() }
  };
  h.advanceTo(capturedAt + 1000);
  await h.observe(result, 7, new Date(capturedAt).toISOString());
  assert.equal(h.native.at(-1).status, "unavailable");
  assert.equal(h.native.at(-1).weekly, null);
  assert.equal(h.native.at(-1).fiveHour, null);
  assert.equal(h.stored.pin, null);
});

test("omitting an expired optional window cannot bypass the pinned account", async () => {
  const h = await revokingHarness();
  const original = h.stored;
  await h.observe({ ...h.result(HASH_B),
    fiveHour: { remainingPercent: 20, resetAt: new Date(original.inFlight.expiresAt - 61_000).toISOString() }
  });
  assert.equal(h.native.at(-1).status, "accountChanged");
  assert.equal(h.native.at(-1).weekly, null);
  assert.equal(h.native.at(-1).fiveHour, null);
  assert.deepEqual(h.stored.pin, original.pin);
  assert.equal(h.stored.connectionID, original.connectionID);
  assert.equal(h.stored.blocked, true);
});

test("automatic retry reserves its budget and deadline across every send boundary", { timeout: 10_000 }, async t => {
  const boundaries = [
    ["before reservation", "storage.beforeSet", false, false],
    ["after reservation", "storage.afterSet", false, true],
    ["before send", "native.beforeSend", false, true],
    ["awaiting ACK", "native.afterSend", true, true],
    ["after ACK", "native.afterAck", true, true],
    ["before failure save", "storage.beforeSet", true, true],
    ["after failure save", "storage.afterSet", true, true],
    ["before alarm creation", "alarms.beforeCreate", true, true]
  ];
  for (const [label, point, sent, reserved] of boundaries) {
    await t.test(label, async () => {
      const h = await revokingHarness(false, true);
      const original = h.stored;
      const attemptAt = original.nextAt;
      const stopped = h.pauseNext(point, value => {
        if (point.startsWith("storage.")) {
          return value.pendingRevocation?.retryCount === 1 && h.native.length === (sent ? 4 : 3);
        }
        return true;
      });
      h.advanceTo(attemptAt);
      h.acks.push({ ok: false, error: "unavailable" });
      h.fireAlarm();
      await stopped;
      assert.equal(h.native.length, sent ? 4 : 3);
      assert.equal(h.stored.pendingRevocation.retryCount, reserved ? 1 : 0);
      assert.equal(h.stored.nextAt, reserved ? attemptAt + 30_000 : attemptAt);
      const persisted = h.stored;
      h.reload();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.equal(h.native.length, sent ? 4 : 3);
      if (reserved) {
        h.fireAlarm();
        await h.flush();
        assert.equal(h.native.length, sent ? 4 : 3);
        assert.equal(h.alarm.scheduledTime, persisted.nextAt);
      }
      h.acks.length = 0;
      h.advanceTo(h.alarm.scheduledTime);
      h.fireAlarm();
      await h.flush();
      assert.deepEqual(h.native.at(-1), original.pendingRevocation.message);
      assert.equal(h.stored.sequence, original.sequence);
      assert.equal(h.stored.connectionID, original.connectionID);
      assert.deepEqual(h.stored.pin, original.pin);
      assert.equal(h.stored.pendingRevocation, null);
      assert.equal(h.stored.blocked, true);
      assert.equal(h.requests.length, 2);
    });
  }
});

test("repeated ACK-wait crashes consume exactly four automatic attempts", { timeout: 10_000 }, async t => {
  for (const recovering of [false, true]) {
    await t.test(recovering ? "recovery" : "terminal", async () => {
      const h = await revokingHarness(recovering, true);
      const original = h.stored;
      for (let retry = 1; retry <= 4; retry++) {
        const attemptAt = h.stored.nextAt;
        h.advanceTo(attemptAt);
        const stopped = h.pauseNext("native.afterSend");
        h.fireAlarm();
        await stopped;
        assert.equal(h.native.length, 3 + retry);
        assert.deepEqual(h.native.at(-1), original.pendingRevocation.message);
        assert.equal(h.stored.pendingRevocation.retryCount, retry);
        assert.equal(h.stored.nextAt, retry < 4 ? attemptAt + [0, 30_000, 60_000, 120_000][retry] : null);
        const persisted = h.stored;
        h.reload();
        await h.flush();
        assert.deepEqual(h.stored, persisted);
        assert.equal(h.native.length, 3 + retry);
        if (retry < 4) {
          h.fireAlarm();
          await h.flush();
          assert.equal(h.native.length, 3 + retry);
          assert.equal(h.alarm.scheduledTime, persisted.nextAt);
        }
      }
      assert.equal(h.alarm, undefined);
      h.fireAlarm();
      h.listener.startup();
      h.listener.updated(7, { status: "complete" }, h.tabs[0]);
      await h.flush();
      assert.equal(h.native.length, 7);
      assert.equal(h.requests.length, 2);
      assert.equal(h.alarm, undefined);
      assert.equal(h.stored.status, "nativeUnavailable");
      assert.deepEqual(h.stored.pin, original.pin);
      assert.equal(h.stored.sequence, original.sequence);
      await h.message({ type: "reconnect" });
      assert.equal(h.native[7].status, "disconnected");
      assert.equal(h.native[7].connectionID, original.connectionID);
      assert.equal(h.native[7].sequence, original.sequence + 1);
      assert.equal(h.native[8].status, "connected");
      assert.equal(h.native[8].sequence, 0);
      assert.notEqual(h.native[8].connectionID, original.connectionID);
      await h.observe(h.result(HASH_B));
      assert.equal(h.stored.pin.accountFingerprint, HASH_B);
    });
  }
});

test("initial accountChanged commits terminal or recovery state atomically across crashes", { timeout: 10_000 }, async t => {
  for (const recovering of [false, true]) {
    const boundaries = [
      ["before pending save", "storage.beforeSet", true],
      ["after pending save", "storage.afterSet", true],
      ["before send", "native.beforeSend"],
      ["awaiting ACK", "native.afterSend"],
      ["after ACK", "native.afterAck"],
      ["before completion save", "storage.beforeSet", false],
      ["after completion save", "storage.afterSet", false],
      ["before alarm update", recovering ? "alarms.beforeCreate" : "alarms.beforeClear"]
    ];
    for (const [label, point, pending] of boundaries) {
      await t.test(`${recovering ? "recovery" : "terminal"}: ${label}`, async () => {
        const h = await revokingHarness(recovering);
        const original = h.stored;
        const stopped = h.pauseNext(point, value => !point.startsWith("storage.")
          || (value.pendingRevocation !== null) === pending);
        void h.observe(h.result(HASH_B));
        await stopped;
        if (label === "before pending save") {
          assert.deepEqual(h.stored, original);
          assert.equal(h.native.length, 2);
          h.reload();
          await h.flush();
          await h.observe(h.result(HASH_B));
        }
        if (!h.stored.pendingRevocation) {
          assert.equal(h.stored.inFlight, null);
          assert.equal(h.stored.status, recovering ? "waitingForAccount" : "accountChanged");
          assert.equal(h.stored.blocked, !recovering);
          assert.equal(h.stored.failureCount, recovering ? 1 : 0);
          assert.equal(h.stored.nextAt, recovering ? original.inFlight.expiresAt - 60_000 + 300_000 : null);
        }
        await assertRestoredRevocation(h, recovering, original);
      });
    }
  }
});

test("retry ACK completion keeps the pending envelope until the final state is saved", { timeout: 10_000 }, async t => {
  for (const recovering of [false, true]) {
    for (const point of ["native.afterAck", "storage.beforeSet", "storage.afterSet", "alarms.beforeClear"]) {
      await t.test(`${recovering ? "recovery" : "terminal"}: ${point}`, async () => {
        const h = await revokingHarness(recovering);
        const original = h.stored;
        h.acks.push({ ok: false, error: "unavailable" });
        await h.observe(h.result(HASH_B));
        const stopped = h.pauseNext(point, value => !point.startsWith("storage.")
          || value.pendingRevocation === null);
        h.advanceTo(h.stored.nextAt);
        h.fireAlarm();
        await stopped;
        if (h.stored.pendingRevocation) assert.equal(h.stored.pendingRevocation.retryCount, 1);
        await assertRestoredRevocation(h, recovering, original);
      });
    }
  }
});

test("pending revocation preserves its mode and deadline on browser startup", async t => {
  for (const recovering of [false, true]) {
    await t.test(recovering ? "recovery" : "terminal", async () => {
      const h = await revokingHarness(recovering, true);
      const original = h.stored;
      h.reload();
      h.listener.startup();
      await h.flush();
      assert.deepEqual(h.stored, original);
      assert.equal(h.alarm.scheduledTime, original.nextAt);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.native.length, 3);
      assert.equal(h.requests.length, 2);
      assert.equal(h.stored.nextAt, original.nextAt);
    });
  }
});

test("closing a terminally revoked tab cannot turn a retry ACK into recovery", async () => {
  const h = await revokingHarness(false, true);
  const original = h.stored;
  h.tabs.splice(0);
  h.listener.removed(7);
  await h.flush();
  h.advanceTo(original.nextAt);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.stored.blocked, true);
  assert.equal(h.stored.recovering, false);
  assert.equal(h.stored.status, "accountChanged");
  assert.equal(h.stored.pendingRevocation, null);
  h.reload();
  await h.flush();
  assert.equal(h.alarm, undefined);
  assert.equal(h.requests.length, 2);
  assert.deepEqual(h.stored.pin, original.pin);
});

test("disconnect ACK crashes retain exact controls until generation cleanup is committed", { timeout: 10_000 }, async t => {
  for (const retry of [false, true]) {
    for (const point of ["native.beforeSend", "native.afterSend", "native.afterAck", "storage.beforeSet", "storage.afterSet"]) {
      await t.test(`${retry ? "explicit retry" : "initial disconnect"}: ${point}`, async () => {
        const h = await revokingHarness();
        const original = h.stored;
        if (retry) {
          h.acks.push({ ok: false, error: "unavailable" });
          await h.message({ type: "disconnect" });
        }
        const stopped = h.pauseNext(point, value => point.startsWith("storage.")
          ? value.pendingDisconnect === false && value.connectionID === null
          : value.status === "disconnected");
        void h.message({ type: retry ? "connect" : "disconnect" });
        await stopped;
        const persisted = h.stored;
        const envelope = persisted.pendingRevocation?.message;
        if (envelope) {
          assert.equal(envelope.status, "disconnected");
          assert.equal(envelope.weekly, null);
          assert.equal(envelope.fiveHour, null);
          assert.equal(persisted.pendingRevocation.retryCount, 0);
          assert.equal(envelope.sequence, original.sequence + 1);
        } else {
          assert.equal(persisted.pendingDisconnect, false);
          assert.equal(persisted.connectionID, null);
          assert.equal(persisted.sequence, null);
          assert.equal(persisted.pin, null);
        }
        const nativeCount = h.native.length;
        h.reload();
        await h.flush();
        assert.deepEqual(h.stored, persisted);
        h.fireAlarm();
        await h.flush();
        assert.equal(h.native.length, nativeCount);
        assert.equal(h.requests.length, 2);
        assert.equal(h.alarm, undefined);
        await h.message({ type: "connect" });
        if (envelope) assert.deepEqual(h.native[nativeCount], envelope);
        const connected = h.native.at(-1);
        assert.equal(connected.status, "connected");
        assert.equal(connected.profileID, original.profileID);
        assert.equal(connected.sequence, 0);
        assert.notEqual(connected.connectionID, original.connectionID);
        assert.equal((await h.message({ type: "observation", requestID: original.inFlight.requestID,
          observedAt: new Date(original.inFlight.expiresAt - 60_000).toISOString(),
          result: h.result(HASH_A) }, h.content(7))).accepted, false);
        await h.observe(h.result(HASH_B));
        assert.equal(h.stored.pin.accountFingerprint, HASH_B);
      });
    }
  }
});

test("unpacked reload restores a missing alarm without sending or changing persisted state", async () => {
  const h = await connectedHarness();
  const persisted = structuredClone(h.stored);
  const alarmCount = h.alarms.length;
  h.advanceTo(persisted.nextAt - 500);
  h.reload();
  await h.flush();
  assert.deepEqual(h.stored, persisted);
  assert.equal(h.alarms.length, alarmCount + 1);
  assert.equal(h.alarm.scheduledTime, persisted.nextAt);
  assert.equal(h.native.length, 2);
  assert.equal(h.requests.length, 1);
  assert.equal(h.scripts.length, 1);
  h.advanceTo(persisted.nextAt);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.requests.length, 2);
  assert.equal(h.native.length, 2);
  await h.observe(h.result(HASH_A));
  assert.equal(h.native[2].connectionID, persisted.connectionID);
  assert.equal(h.native[2].sequence, persisted.sequence + 1);
  assert.deepEqual(structuredClone(h.stored.pin), persisted.pin);
});

test("reload arms elapsed or missing deadlines soon and leaves polling to the alarm", async t => {
  for (const missing of [false, true]) {
    await t.test(missing ? "missing deadline" : "elapsed deadline", async () => {
      const h = await connectedHarness();
      const now = h.stored.nextAt + 10_000;
      h.advanceTo(now);
      if (missing) h.editStored(value => { value.nextAt = null; });
      const persisted = structuredClone(h.stored);
      h.reload();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.ok(h.alarm.scheduledTime > now && h.alarm.scheduledTime <= now + 1_000);
      assert.equal(h.native.length, 2);
      assert.equal(h.requests.length, 1);
      h.advanceTo(h.alarm.scheduledTime);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.requests.length, 2);
      assert.equal(h.native.length, 2);
    });
  }
});

test("worker initialization leaves an existing alarm unchanged", async () => {
  const h = await connectedHarness();
  const alarm = structuredClone(h.alarm);
  const alarmCount = h.alarms.length;
  const persisted = structuredClone(h.stored);
  h.reload({ keepAlarm: true });
  await h.flush();
  assert.deepEqual(h.alarm, alarm);
  assert.equal(h.alarms.length, alarmCount);
  assert.deepEqual(h.stored, persisted);
  assert.equal(h.native.length, 2);
  assert.equal(h.requests.length, 1);
});

test("reload preserves failure backoff and early alarm events cannot bypass it", async t => {
  for (const status of ["unavailable", "rateLimited"]) {
    await t.test(status, async () => {
      const h = await connectedHarness();
      for (let count = 0; count < 3; count += 1) {
        h.fireDueAlarm();
        await h.flush();
        await h.observe({ status });
      }
      const persisted = structuredClone(h.stored);
      h.reload();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.equal(h.alarm.scheduledTime, persisted.nextAt);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.native.length, 5);
      assert.equal(h.requests.length, 4);
      assert.equal(h.stored.failureCount, 3);
      assert.equal(h.stored.nextAt, persisted.nextAt);
      h.advanceTo(persisted.nextAt);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.requests.length, 5);
      assert.equal(h.native.length, 5);
    });
  }
});

test("reload preserves in-flight expiry and diagnoses timeout only on the alarm", async t => {
  for (const expired of [false, true]) {
    await t.test(expired ? "expired" : "unexpired", async () => {
      const h = await connectedHarness();
      h.advanceTo(h.stored.nextAt);
      h.fireAlarm();
      await h.flush();
      const persisted = structuredClone(h.stored);
      const now = expired ? persisted.inFlight.expiresAt + 1 : persisted.inFlight.expiresAt - 30_000;
      h.advanceTo(now);
      h.reload();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.equal(h.native.length, 2);
      assert.equal(h.requests.length, 2);
      if (!expired) {
        assert.equal(h.alarm.scheduledTime, persisted.inFlight.expiresAt);
        h.fireAlarm();
        await h.flush();
        assert.equal(h.alarm.scheduledTime, persisted.inFlight.expiresAt);
        assert.equal(h.native.length, 2);
      } else {
        assert.ok(h.alarm.scheduledTime > now && h.alarm.scheduledTime <= now + 1_000);
      }
      h.advanceTo(h.alarm.scheduledTime);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.stored.inFlight, null);
      assert.equal(h.stored.lastFailureStage, "responseTimeout");
      assert.equal(h.stored.failureCount, 1);
      assert.equal(h.native[2].status, "unavailable");
      assert.equal(h.native[2].connectionID, persisted.connectionID);
      assert.equal(h.native[2].sequence, persisted.sequence + 1);
      assert.equal(h.requests.length, 2);
    });
  }
});

test("alarm wakeup during initialization cannot cause duplicate immediate polls", async () => {
  const h = await connectedHarness();
  h.advanceTo(h.stored.nextAt);
  h.reload();
  h.fireAlarm();
  await h.flush();
  assert.equal(h.requests.length, 2);
  assert.equal(h.native.length, 2);
  assert.equal(h.alarm.scheduledTime, h.stored.inFlight.expiresAt);
  await h.observe(h.result(HASH_A));
  const deadline = h.stored.nextAt;
  // A restored immediate alarm may already be queued when observation completes.
  h.fireAlarm();
  await h.flush();
  assert.equal(h.requests.length, 2);
  assert.equal(h.native.length, 3);
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.alarm.scheduledTime, deadline);
});

test("reload preserves revocation deadlines and the four-retry bound", async () => {
  const h = await connectedHarness();
  h.fireDueAlarm();
  await h.flush();
  h.acks.push({ ok: false, error: "unavailable" });
  await h.observe(h.result(HASH_B));
  const envelope = structuredClone(h.stored.pendingRevocation.message);
  for (let retry = 0; retry < 4; retry += 1) {
    const persisted = structuredClone(h.stored);
    const nativeCount = h.native.length;
    h.reload();
    await h.flush();
    assert.deepEqual(h.stored, persisted);
    assert.equal(h.alarm.scheduledTime, persisted.nextAt);
    assert.equal(h.native.length, nativeCount);
    h.fireAlarm();
    await h.flush();
    assert.equal(h.native.length, nativeCount);
    assert.equal(h.alarm.scheduledTime, persisted.nextAt);
    h.advanceTo(persisted.nextAt);
    h.acks.push({ ok: false, error: "unavailable" });
    h.fireAlarm();
    await h.flush();
    assert.equal(h.native.length, nativeCount + 1);
    assert.deepEqual(structuredClone(h.native.at(-1)), envelope);
    assert.equal(h.stored.pendingRevocation.retryCount, retry + 1);
    assert.equal(h.stored.sequence, envelope.sequence);
    assert.equal(h.requests.length, 2);
  }
  assert.equal(h.stored.nextAt, null);
  const persisted = structuredClone(h.stored);
  const nativeCount = h.native.length;
  const alarmCount = h.alarms.length;
  h.reload();
  await h.flush();
  assert.equal(h.alarm, undefined);
  assert.equal(h.alarms.length, alarmCount);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.native.length, nativeCount);
  assert.equal(h.requests.length, 2);
  assert.deepEqual(h.stored, persisted);
});

test("restored revocation retries its exact envelope only when the alarm is due", async () => {
  const h = await connectedHarness();
  h.fireDueAlarm();
  await h.flush();
  h.acks.push({ ok: false, error: "unavailable" });
  await h.observe(h.result(HASH_B));
  const persisted = structuredClone(h.stored);
  h.reload();
  await h.flush();
  assert.equal(h.native.length, 3);
  assert.equal(h.requests.length, 2);
  h.advanceTo(h.alarm.scheduledTime);
  h.fireAlarm();
  await h.flush();
  assert.deepEqual(structuredClone(h.native[3]), persisted.pendingRevocation.message);
  assert.equal(h.stored.pendingRevocation, null);
  assert.equal(h.stored.sequence, persisted.sequence);
  assert.equal(h.stored.connectionID, persisted.connectionID);
  assert.deepEqual(structuredClone(h.stored.pin), persisted.pin);
  assert.equal(h.stored.nextAt, null);
  assert.equal(h.alarm, undefined);
  assert.equal(h.requests.length, 2);
});

test("reload does not resume disabled, blocked, pending Connect, or disconnected states", async t => {
  for (const mode of ["disabled", "blocked", "pendingConnect", "disconnected", "pendingDisconnect"]) {
    await t.test(mode, async () => {
      const h = await connectedHarness();
      if (mode === "disabled") h.editStored(value => { value.enabled = false; });
      if (mode === "blocked") h.editStored(value => { value.blocked = true; });
      if (mode === "pendingDisconnect") h.acks.push({ ok: false, error: "unavailable" });
      if (["pendingConnect", "disconnected", "pendingDisconnect"].includes(mode)) {
        await h.message({ type: "disconnect" });
      }
      if (mode === "pendingConnect") {
        h.acks.push({ ok: false, error: "unavailable" });
        await h.message({ type: "connect" });
      }
      const persisted = structuredClone(h.stored);
      const nativeCount = h.native.length;
      const requestCount = h.requests.length;
      const alarmCount = h.alarms.length;
      h.reload();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.equal(h.alarm, undefined);
      assert.equal(h.alarms.length, alarmCount);
      h.fireAlarm();
      await h.flush();
      assert.deepEqual(h.stored, persisted);
      assert.equal(h.native.length, nativeCount);
      assert.equal(h.requests.length, requestCount);
      assert.equal(h.scripts.length, requestCount);
      assert.equal(h.alarm, undefined);
    });
  }
});

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

test("failed signout and organization invalidations retry before any observation and recover by status", async t => {
  for (const status of ["signedOut", "organizationSelectionRequired"]) {
    for (const recovering of [false, true]) {
      await t.test(`${status}: recovering=${recovering}`, async () => {
        const h = await revokingHarness(recovering);
        const original = h.stored;
        h.acks.push({ ok: false, error: "bridgeBusy" });
        await h.observe({ status });
        const pending = h.stored.pendingRevocation;
        assert.ok(pending);
        assert.equal(pending.message.status, status);
        for (const key of ["weekly", "fiveHour", "accountFingerprint", "organizationFingerprint", "principalFingerprint"]) {
          assert.equal(pending.message[key], null);
        }
        h.reload(); h.listener.startup(); await h.flush();
        const deadline = h.stored.nextAt;
        h.fireAlarm();
        h.listener.updated(7, { status: "complete" }, h.tabs[0]);
        await h.flush();
        assert.equal(h.native.length, 3);
        assert.equal(h.requests.length, 2);
        assert.equal(h.stored.nextAt, deadline);
        h.advanceTo(deadline); h.fireAlarm(); await h.flush();
        assert.deepEqual(h.native.at(-1), pending.message);
        assert.equal(h.stored.pendingRevocation, null);
        assert.equal(h.stored.status, status);
        assert.deepEqual(h.stored.pin, original.pin);
        assert.equal(h.stored.connectionID, original.connectionID);
        assert.equal(h.requests.length, 2);
        if (status === "signedOut") {
          assert.equal(h.stored.blocked, false);
          assert.equal(h.stored.failureCount, 1);
          assert.equal(h.stored.nextAt, deadline + 300_000);
          h.fireAlarm(); await h.flush();
          assert.equal(h.requests.length, 2);
          h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
          await h.observe(h.result(HASH_B));
          assert.equal(h.native.at(-1).status, "accountChanged");
          assert.deepEqual(h.stored.pin, original.pin);
        } else {
          assert.equal(h.stored.blocked, true);
          assert.equal(h.alarm, undefined);
          h.listener.startup();
          h.listener.updated(7, { status: "complete" }, h.tabs[0]);
          await h.flush();
          assert.equal(h.requests.length, 2);
        }
      });
    }
  }
});

test("new invalidations survive initial-send and ACK-completion worker eviction", { timeout: 10_000 }, async t => {
  for (const status of ["signedOut", "organizationSelectionRequired"]) {
    for (const retry of [false, true]) {
      for (const point of ["native.beforeSend", "native.afterSend", "native.afterAck", "storage.beforeSet", "storage.afterSet",
        status === "signedOut" ? "alarms.beforeCreate" : "alarms.beforeClear"]) {
        await t.test(`${status}: retry=${retry}: ${point}`, async () => {
          const h = await revokingHarness();
          const original = h.stored;
          if (retry) {
            h.acks.push({ ok: false, error: "bridgeBusy" });
            await h.observe({ status });
            assert.ok(h.stored.pendingRevocation);
          }
          const stopped = h.pauseNext(point, value => !point.startsWith("storage.")
            || value.pendingRevocation === null && value.status === status);
          if (retry) { h.advanceTo(h.stored.nextAt); h.fireAlarm(); }
          else void h.observe({ status });
          await stopped;
          const saved = h.stored;
          assert.equal(saved.inFlight, null);
          h.reload(); await h.flush();
          assert.deepEqual(h.stored, saved);
          if (saved.pendingRevocation) {
            const envelope = saved.pendingRevocation.message;
            h.advanceTo(saved.nextAt); h.fireAlarm(); await h.flush();
            assert.deepEqual(h.native.at(-1), envelope);
          }
          assert.equal(h.stored.pendingRevocation, null);
          assert.equal(h.stored.status, status);
          assert.equal(h.stored.blocked, status === "organizationSelectionRequired");
          assert.deepEqual(h.stored.pin, original.pin);
          assert.equal(h.stored.connectionID, original.connectionID);
          assert.equal(h.requests.length, 2);
          assert.equal(h.stored.failureCount, status === "signedOut" ? 1 : 0);
        });
      }
    }
  }
});

test("new invalidations exhaust four retries even across ACK-wait eviction and lost tabs", { timeout: 10_000 }, async t => {
  for (const status of ["signedOut", "organizationSelectionRequired"]) {
    await t.test(status, async () => {
      const h = await revokingHarness();
      const original = h.stored;
      h.acks.push({ ok: false, error: "bridgeBusy" });
      await h.observe({ status });
      assert.ok(h.stored.pendingRevocation);
      const envelope = h.stored.pendingRevocation.message;
      h.tabs.splice(0); h.listener.removed(7); await h.flush();
      for (let retry = 1; retry <= 4; retry++) {
        h.advanceTo(h.stored.nextAt);
        const stopped = h.pauseNext("native.afterSend");
        h.fireAlarm(); await stopped;
        assert.deepEqual(h.native.at(-1), envelope);
        assert.equal(h.stored.pendingRevocation.retryCount, retry);
        h.reload(); h.listener.startup(); await h.flush();
      }
      h.tabs.push({ id: 8, url: URL_ON_TAB, active: true });
      h.listener.updated(8, { status: "complete" }, h.tabs[0]);
      h.fireAlarm(); await h.flush();
      assert.equal(h.native.length, 7);
      assert.equal(h.requests.length, 2);
      assert.equal(h.alarm, undefined);
      assert.equal(h.stored.nextAt, null);
      assert.equal(h.stored.status, "nativeUnavailable");
      assert.deepEqual(h.stored.pin, original.pin);
      await h.message({ type: "reconnect" });
      assert.equal(h.native[7].status, "disconnected");
      assert.equal(h.native[7].connectionID, original.connectionID);
      assert.equal(h.native[8].status, "connected");
      assert.notEqual(h.native[8].connectionID, original.connectionID);
      await h.observe(h.result(HASH_B), 8);
      assert.equal(h.stored.pin.accountFingerprint, HASH_B);
    });
  }
});

test("signout transport recovery resumes the same pinned account after a lost tab", async () => {
  let unavailable = true;
  const h = harness({ nativeHandler: async message => {
    if (message.status === "signedOut" && unavailable) {
      unavailable = false;
      throw new Error("synthetic transport failure");
    }
    return { ok: true };
  } });
  await h.message({ type: "connect" });
  await h.observe(h.result(HASH_A));
  const original = h.stored;
  h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
  const request = h.stored.inFlight;
  await h.observe({ status: "signedOut" });
  assert.equal(h.stored.status, "nativeUnavailable");
  assert.ok(h.stored.pendingRevocation);
  assert.equal((await h.message({ type: "observation", requestID: request.requestID,
    observedAt: new Date(request.expiresAt - 60_000).toISOString(), result: h.result(HASH_B)
  }, h.content(7))).accepted, false);
  h.tabs.splice(0); h.listener.removed(7); await h.flush();
  h.reload(); h.listener.startup(); await h.flush();
  h.tabs.push({ id: 8, url: URL_ON_TAB, active: true });
  h.listener.updated(8, { status: "complete" }, h.tabs[0]); await h.flush();
  assert.equal(h.requests.length, 2);
  h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
  assert.equal(h.stored.status, "signedOut");
  assert.equal(h.requests.length, 2);
  h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
  assert.equal(h.stored.inFlight.tabID, 8);
  await h.observe(h.result(HASH_A), 8);
  assert.equal(h.stored.status, "ok");
  assert.equal(h.stored.recovering, false);
  assert.equal(h.stored.failureCount, 0);
  assert.deepEqual(h.stored.pin, original.pin);
  assert.equal(h.stored.connectionID, original.connectionID);
});

test("rejected invalidations keep exact retry delays and stop after four automatic retries", async t => {
  for (const status of ["signedOut", "organizationSelectionRequired"]) {
    await t.test(status, async () => {
      const h = await revokingHarness();
      const observed = h.stored.inFlight.expiresAt - 60_000;
      h.acks.push(...Array.from({ length: 5 }, () => ({ ok: false, error: "bridgeBusy" })));
      await h.observe({ status });
      const envelope = h.stored.pendingRevocation.message;
      let previousAttempt = observed;
      for (const delay of [15_000, 30_000, 60_000, 120_000]) {
        assert.equal(h.stored.nextAt, previousAttempt + delay);
        previousAttempt = h.stored.nextAt;
        h.advanceTo(previousAttempt); h.fireAlarm(); await h.flush();
        assert.deepEqual(h.native.at(-1), envelope);
      }
      h.reload(); h.listener.startup(); h.fireAlarm(); await h.flush();
      assert.equal(h.native.length, 7);
      assert.equal(h.stored.pendingRevocation.retryCount, 4);
      assert.equal(h.alarm, undefined);
      assert.equal(h.requests.length, 2);
    });
  }
});

test("confirmed ownership changes revoke even when usage parsing or delivery validation fails", async t => {
  const { observe } = require("../protocol.js");
  const account = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const org = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  for (const mode of ["parserFailure", "deliveryExpiry", "invalidOptionalWindow"]) {
    await t.test(mode, async () => {
      const h = await revokingHarness();
      const original = h.stored;
      let result;
      if (mode === "parserFailure") {
        const now = original.inFlight.expiresAt - 60_000;
        const replies = [{ uuid: account }, [{ uuid: org }],
          { seven_day: { utilization: 27, resets_at: new Date(now).toISOString() } }, { uuid: account }];
        result = await observe({ now: () => now,
          fetchImpl: async () => new Response(JSON.stringify(replies.shift())) });
        assert.equal(result.status, "unavailable");
      } else {
        result = h.result(HASH_B);
        if (mode === "deliveryExpiry") result.weekly.resetAt = new Date(original.inFlight.expiresAt - 60_000).toISOString();
        else result.fiveHour = { remainingPercent: 101, resetAt: result.weekly.resetAt };
      }
      await h.observe(result);
      assert.equal(h.native.at(-1).status, "accountChanged");
      assert.equal(h.native.at(-1).accountFingerprint, null);
      assert.equal(h.native.at(-1).weekly, null);
      assert.deepEqual(h.stored.pin, original.pin);
      assert.equal(h.stored.blocked, true);
    });
  }
});

test("failed usage never pins an account and incomplete ownership cannot revoke an existing pin", async () => {
  const h = harness();
  await h.message({ type: "connect" });
  await h.observe({ ...h.result(HASH_B), status: "unavailable", weekly: null });
  assert.equal(h.stored.pin, null);
  assert.equal(h.native.at(-1).accountFingerprint, null);
  h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
  await h.observe(h.result(HASH_A));
  const pin = h.stored.pin;
  for (const result of [
    { ...h.result(HASH_A), status: "unavailable", weekly: null },
    { ...h.result(HASH_B), status: "unavailable", principalFingerprint: null },
    { ...h.result(HASH_B), status: "unavailable", organizationFingerprint: "invalid" },
    { ...h.result(HASH_B), status: "notRecognized" }
  ]) {
    h.advanceTo(h.stored.nextAt); h.fireAlarm(); await h.flush();
    await h.observe(result);
    assert.equal(h.native.at(-1).status, "unavailable");
    assert.equal(h.native.at(-1).accountFingerprint, null);
    assert.deepEqual(h.stored.pin, pin);
    assert.equal(h.stored.blocked, false);
  }
});

test("explicit aged Connect and Disconnect retries renew only the handshake time before sending", async t => {
  for (const accepted of [false, true]) {
    for (const command of ["connect", "disconnect"]) {
      await t.test(`accepted=${accepted}: ${command}`, async () => {
        let attempts = 0;
        let hostHandshake = null;
        let h;
        h = harness({ nativeHandler: async (message, now) => {
          if (message.status !== "connected") return { ok: true };
          assert.deepEqual(h.stored.pendingConnectedMessage, message);
          if (now - Date.parse(message.observedAt) > 300_000) return { ok: false, error: "invalidMessage" };
          if (++attempts === 1) {
            if (accepted) hostHandshake = structuredClone(message);
            throw new Error("synthetic lost ACK or unavailable host");
          }
          hostHandshake ??= structuredClone(message);
          return { ok: true };
        } });
        const start = Date.parse("2026-09-30T00:00:00.000Z");
        h.advanceTo(start);
        await h.message({ type: "connect" });
        const original = h.stored.pendingConnectedMessage;
        assert.ok(original);
        h.advanceTo(start + 301_000);
        h.reload(); h.listener.startup(); h.fireAlarm(); await h.flush();
        assert.deepEqual(h.stored.pendingConnectedMessage, original);
        assert.equal(h.native.length, 1);
        await h.message({ type: command });
        assert.deepEqual(h.native[1], { ...original, observedAt: new Date(start + 301_000).toISOString() });
        assert.equal(h.stored.pendingConnect, false);
        assert.equal(h.stored.pin, null);
        assert.equal(h.stored.enabled, command === "connect");
        assert.equal(h.requests.length, command === "connect" ? 1 : 0);
        assert.equal(hostHandshake.observedAt, accepted ? original.observedAt : h.native[1].observedAt);
        if (command === "disconnect") assert.equal(h.native[2].status, "disconnected");
      });
    }
  }
});

test("explicit handshake freshness is durable across worker eviction without automatic resend", { timeout: 10_000 }, async t => {
  for (const command of ["connect", "disconnect"]) {
    for (const point of ["storage.beforeSet", "storage.afterSet", "native.beforeSend", "native.afterSend", "native.afterAck"]) {
      await t.test(`${command}: ${point}`, async () => {
        const h = harness();
        const start = Date.parse("2026-09-30T00:00:00.000Z");
        h.advanceTo(start);
        h.acks.push({ ok: false, error: "bridgeBusy" });
        await h.message({ type: "connect" });
        const original = h.stored.pendingConnectedMessage;
        const retryAt = start + 301_000;
        h.advanceTo(retryAt);
        const stopped = h.pauseNext(point, value => point.startsWith("storage.")
          ? value.pendingConnect && value.pendingConnectedMessage.observedAt === new Date(retryAt).toISOString()
          : value.status === "connected");
        void h.message({ type: command });
        await stopped;
        const saved = h.stored;
        assert.deepEqual(saved.pendingConnectedMessage, { ...original,
          observedAt: point === "storage.beforeSet" ? original.observedAt : new Date(retryAt).toISOString() });
        const count = h.native.length;
        h.reload(); h.listener.startup(); h.fireAlarm(); await h.flush();
        assert.deepEqual(h.stored, saved);
        assert.equal(h.native.length, count);
        assert.equal(h.requests.length, 0);
        h.advanceTo(retryAt + 301_000);
        await h.message({ type: command });
        assert.deepEqual(h.native[count], { ...original, observedAt: new Date(retryAt + 301_000).toISOString() });
        assert.equal(h.stored.pendingConnect, false);
        assert.equal(h.stored.enabled, command === "connect");
      });
    }
  }
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

test("connected ACK failure sends no observation and only renews time on explicit Connect", async () => {
  const h = harness();
  h.advanceTo(Date.parse("2026-09-30T00:00:00.000Z"));
  h.acks.push({ ok: false, error: "unavailable" });
  await h.message({ type: "connect" });
  assert.equal(h.stored.enabled, false);
  assert.equal(h.stored.pendingConnect, true);
  assert.equal(h.stored.inFlight, null);
  h.advanceTo(Date.parse("2026-09-30T00:00:05.000Z"));
  await h.message({ type: "connect" });
  assert.deepEqual(h.native[1], { ...h.native[0], observedAt: "2026-09-30T00:00:05.000Z" });
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
  h.editStored(value => { value.inFlight.expiresAt = Date.now() - 1; });
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
  const completedAt = new Date(h.now).toISOString();
  h.advanceTo(h.now + 10);
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
    const expiredAt = h.stored.inFlight.expiresAt;
    h.fireDueAlarm();
    await h.flush();
    assert.equal(h.stored.inFlight, null);
    assert.equal(h.stored.lastFailureStage, "responseTimeout");
    assert.equal(h.native.at(-1).status, "unavailable");
    assert.equal(h.native.at(-1).weekly, null);
    assert.equal(h.stored.nextAt, expiredAt + minutes * 60_000);
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
  h.advanceTo(h.stored.nextAt);
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
  assert.equal(h.stored.inFlight, null);
  assert.equal(h.requests.length, 1);
  h.fireDueAlarm();
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
  h.advanceTo(h.stored.nextAt);
  h.listener.startup();
  await h.flush();
  h.advanceTo(h.stored.inFlight.expiresAt);
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
  h.advanceTo(h.stored.nextAt);
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

test("app revocation after a lost Connect ACK retires the pending control rather than retrying forever", async t => {
  for (const command of ["connect", "disconnect"]) {
    await t.test(command, async () => {
      const h = harness();
      h.acks.push(null);
      await h.message({ type: "connect" });
      assert.equal(h.stored.pendingConnect, true);
      const retired = h.stored.connectionID;
      const deadline = Date.now() + 15 * 60 * 1000;
      h.editStored(value => { value.pollNotBefore = deadline; });
      h.acks.push({ ok: false, error: "connectionMismatch" });
      await h.message({ type: command });
      assert.equal(h.stored.status, "connectRequired");
      assert.equal(h.stored.pendingConnect, false);
      assert.equal(h.stored.pendingDisconnect, false);
      assert.equal(h.stored.pendingConnectedMessage, null);
      assert.equal(h.stored.connectionID, null);
      assert.equal(h.stored.enabled, false);
      assert.equal(h.stored.pollNotBefore, deadline);
      h.reload();
      await h.flush();
      await h.message({ type: "connect" });
      assert.notEqual(h.stored.connectionID, retired);
      assert.equal(h.stored.enabled, true);
      assert.equal(h.stored.pollNotBefore, deadline);
      assert.equal(h.requests.length, 0);
    });
  }
});

test("app revocation retires a pending disconnect and a pending signout control", async t => {
  for (const control of ["disconnect", "signedOut"]) {
    await t.test(control, async () => {
      const h = harness();
      await h.message({ type: "connect" });
      h.acks.push(null);
      if (control === "disconnect") await h.message({ type: "disconnect" });
      else await h.observe({ status: "signedOut" });
      assert.notEqual(h.stored.pendingRevocation, null);
      h.acks.push({ ok: false, error: "connectionMismatch" });
      if (control === "disconnect") await h.message({ type: "disconnect" });
      else { h.fireDueAlarm(); await h.flush(); }
      assert.equal(h.stored.status, "connectRequired");
      assert.equal(h.stored.enabled, false);
      assert.equal(h.stored.pendingRevocation, null);
      assert.equal(h.stored.connectionID, null);
      assert.equal(h.stored.pendingDisconnect, false);
    });
  }
});

test("app-side revocation stops the worker after the rejected observation and preserves waits", async t => {
  for (const status of ["ok", "rateLimited", "signedOut"]) {
    await t.test(status, async () => {
      const h = harness();
      await h.message({ type: "connect" });
      const oldConnection = h.stored.connectionID;
      h.acks.push({ ok: false, error: "connectionMismatch" });
      await h.observe(status === "ok" ? h.result(HASH_A) : { status });
      assert.equal(h.stored.enabled, false);
      assert.equal(h.stored.status, "connectRequired");
      assert.equal(h.stored.pin, null);
      assert.equal(h.stored.connectionID, null);
      assert.equal(h.stored.pendingRevocation, null);
      assert.equal(h.stored.inFlight, null);
      assert.equal(h.stored.nextAt, null);
      const notBefore = h.stored.pollNotBefore;
      assert.ok(notBefore > Date.now());
      if (status === "rateLimited") assert.ok(notBefore - Date.now() >= 15 * 60 * 1000 - 1000);
      const calls = h.requests.length;
      h.reload();
      await h.flush();
      h.fireAlarm();
      await h.flush();
      assert.equal(h.requests.length, calls);
      await h.message({ type: "connect" });
      assert.notEqual(h.stored.connectionID, oldConnection);
      assert.equal(h.stored.pollNotBefore, notBefore);
      assert.equal(h.requests.length, calls);
      h.advanceTo(notBefore);
      h.fireAlarm();
      await h.flush();
      assert.equal(h.requests.length, calls + 1);
    });
  }
});

test("reconnect and consent toggles preserve provider polling deadlines", async t => {
  const start = Date.parse("2026-10-01T00:00:00.000Z");
  for (const status of ["ok", "rateLimited", "unavailable"]) {
    for (const toggleConsent of [false, true]) {
      await t.test(`${status}: ${toggleConsent ? "Disconnect/Connect" : "Reconnect"}`, async () => {
        const h = harness();
        h.advanceTo(start);
        await h.message({ type: "connect" });
        await h.observe(status === "ok" ? h.result(HASH_A) : { status });
        const original = h.stored;
        const deadline = start + (status === "rateLimited" ? 900_000 : 300_000);
        assert.equal(original.nextAt, deadline);
        h.advanceTo(start + 1_000);
        for (let attempt = 0; attempt < 2; attempt++) {
          if (toggleConsent) {
            await h.message({ type: "disconnect" });
            assert.equal(h.stored.enabled, false);
            assert.equal(h.stored.nextAt, null);
            assert.equal(h.alarm, undefined);
            h.reload();
            h.listener.startup();
            h.fireAlarm();
            await h.flush();
            assert.equal(h.alarm, undefined);
          }
          await h.message({ type: toggleConsent ? "connect" : "reconnect" });
          assert.equal(h.stored.enabled, true);
          assert.notEqual(h.stored.connectionID, original.connectionID);
          assert.equal(h.stored.pin, null);
          assert.equal(h.requests.length, 1);
          assert.equal(h.scripts.length, 1);
          assert.equal(h.stored.inFlight, null);
          assert.equal(h.stored.pollNotBefore, deadline);
          assert.equal(h.stored.nextAt, deadline);
          assert.equal(h.alarm.scheduledTime, deadline);
          for (const message of h.native.slice(2)) {
            assert.ok(["connected", "disconnected"].includes(message.status));
            for (const key of ["weekly", "fiveHour", "accountFingerprint", "organizationFingerprint", "principalFingerprint"]) {
              assert.equal(message[key], null);
            }
            assert.equal(Object.hasOwn(message, "pollNotBefore"), false);
          }
        }
        h.advanceTo(deadline - 1);
        h.reload();
        h.listener.startup();
        h.listener.updated(7, { status: "complete" }, h.tabs[0]);
        h.fireAlarm();
        await h.flush();
        assert.equal(h.requests.length, 1);
        assert.equal(h.stored.nextAt, deadline);
        assert.equal(h.alarm.scheduledTime, deadline);
        h.advanceTo(deadline);
        h.fireAlarm();
        await h.flush();
        assert.equal(h.requests.length, 2);
        await h.observe(h.result(HASH_B));
        assert.equal(h.stored.pin.accountFingerprint, HASH_B);
        assert.equal(h.stored.nextAt, deadline + 300_000);
        for (const snapshot of h.writes) {
          assert.equal(Object.hasOwn(snapshot, "weekly"), false);
          assert.equal(Object.hasOwn(snapshot, "fiveHour"), false);
        }
      });
    }
  }
});

test("a persisted provider deadline beyond local backoff survives consent, reconnect and clock rollback", async () => {
  const start = Date.parse("2026-10-01T00:00:00.000Z");
  const deadline = start + 24 * 60 * 60 * 1000;
  const h = harness();
  h.advanceTo(start);
  await h.message({ type: "connect" });
  await h.observe({ status: "rateLimited" });
  // Legacy storage contains only nextAt; do not clamp a valid provider minimum to MAX_BACKOFF.
  h.editStored(value => { delete value.pollNotBefore; value.nextAt = deadline; });
  h.reload();
  await h.flush();
  h.advanceTo(start - 60_000);
  await h.message({ type: "disconnect" });
  assert.equal(h.stored.pollNotBefore, deadline);
  assert.equal(h.alarm, undefined);
  h.reload();
  await h.message({ type: "connect" });
  await h.message({ type: "reconnect" });
  assert.equal(h.stored.nextAt, deadline);
  assert.equal(h.alarm.scheduledTime, deadline);
  assert.equal(h.requests.length, 1);
  h.advanceTo(deadline - 1);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.requests.length, 1);
  h.advanceTo(deadline);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.requests.length, 2);
});

test("failed disconnect and Connect ACKs cannot erase provider backoff", async () => {
  const h = harness();
  const start = Date.parse("2026-10-01T00:00:00.000Z");
  h.advanceTo(start);
  await h.message({ type: "connect" });
  await h.observe({ status: "rateLimited" });
  const deadline = h.stored.nextAt;
  h.acks.push({ ok: false, error: "unavailable" });
  await h.message({ type: "reconnect" });
  assert.equal(h.stored.pendingDisconnect, true);
  const disconnected = h.native.at(-1);
  h.reload();
  h.acks.push({ ok: true }, { ok: false, error: "unavailable" });
  await h.message({ type: "connect" });
  assert.deepEqual(h.native.at(-2), disconnected);
  assert.equal(h.stored.pendingConnect, true);
  assert.equal(h.alarm, undefined);
  h.reload();
  h.advanceTo(start + 1_000);
  await h.message({ type: "connect" });
  assert.equal(h.stored.pendingConnect, false);
  assert.equal(h.stored.nextAt, deadline);
  assert.equal(h.stored.pollNotBefore, deadline);
  assert.equal(h.alarm.scheduledTime, deadline);
  assert.equal(h.requests.length, 1);
});

test("startup and tab recovery cannot shorten the successful five-minute poll interval", async () => {
  const h = await connectedHarness();
  const original = h.stored;
  const deadline = original.nextAt;
  h.advanceTo(deadline - 1);
  h.listener.startup();
  h.tabs.splice(0);
  h.listener.removed(7);
  await h.flush();
  h.tabs.push({ id: 8, url: URL_ON_TAB, active: true });
  h.listener.updated(8, { status: "complete" }, h.tabs[0]);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.stored.nextAt, deadline);
  assert.equal(h.alarm.scheduledTime, deadline);
  assert.equal(h.requests.length, 1);
  assert.equal(h.native.length, 2);
  assert.deepEqual(h.stored.pin, original.pin);
  assert.equal(h.stored.connectionID, original.connectionID);
  h.advanceTo(deadline);
  h.fireAlarm();
  await h.flush();
  assert.equal(h.stored.inFlight.tabID, 8);
  assert.equal(h.requests.length, 2);
  await h.observe(h.result(HASH_A), 8);
  assert.equal(h.stored.status, "ok");
  assert.equal(h.stored.connectionID, original.connectionID);
});
