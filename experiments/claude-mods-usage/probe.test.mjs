import assert from "node:assert/strict";
import test from "node:test";
import { chmod, lstat, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { realpath } from "node:fs/promises";
import { join } from "node:path";
import { createUsageProducer } from "./producer.mjs";
import { createComparisonReceiver, decodeGrant, encodeMessage, MAX_BYTES } from "./protocol.mjs";
import { prepareDirectory, inspectStream } from "./receiver.mjs";
import { register } from "./hooks/register.mjs";
import { TEST_PUBLIC_KEY, openRequest } from "./tests/crypto-fixture.mjs";

const T0 = "2026-10-06T00:00:00.000Z";
const NOW = Date.parse(T0);
const WEEK = "2026-10-13T00:00:00.000Z";
const CONNECTION = "11111111-1111-4111-8111-111111111111";
const STREAM = "22222222-2222-4222-8222-222222222222";
const OTHER = "33333333-3333-4333-8333-333333333333";
const DIRECTORY = "/private/probe fixture";
const grant = { schemaVersion: 1, purpose: "quotatempo-mods-comparison", connectionID: CONNECTION, createdAt: T0 };
const UNIX_DIRECTORY = `/private/tmp/qtc-${OTHER}`;
const unixGrant = { ...grant, schemaVersion: 3, transport: "unix-hpke", socketPath: `${UNIX_DIRECTORY}/bridge.sock` };
const DISCONNECT_UNCONFIRMED = "QuotaTempo probe stopped locally. Disconnect confirmation failed; prepare a new private comparison directory. No product source was changed.";
const usage = (percentUsed = 42, resetsAt = WEEK) => ({ rateLimits: [{ kind: "seven_day", percentUsed, resetsAt }] });

function timerHarness() {
  const pending = new Map();
  let elapsed = 0;
  let serial = 0;
  let cancelled = 0;
  return {
    after(ms, fn) {
      assert.equal(ms, 5_000);
      const id = ++serial;
      pending.set(id, { at: elapsed + ms, fn });
      return { cancel() { cancelled++; pending.delete(id); } };
    },
    advance(ms) {
      elapsed += ms;
      for (const [id, timer] of pending) {
        if (timer.at <= elapsed) { pending.delete(id); timer.fn(); }
      }
    },
    pending: () => pending.size,
    cancelled: () => cancelled,
  };
}

async function message(input = usage(), readAt = T0, sequence = 1) {
  let result;
  await createUsageProducer({ getUsage: () => input, clock: () => readAt, sink: value => { result = value; } }).poll();
  return { schemaVersion: 1, connectionID: CONNECTION, streamID: STREAM, sequence, result };
}
const receiver = () => createComparisonReceiver({ connectionID: CONNECTION, streamID: STREAM });

function harness({ directory = DIRECTORY, grantValue = grant } = {}) {
  const hooks = new Map();
  const files = new Map([[`${directory}/probe-grant.json`, JSON.stringify(grantValue)]]);
  const writes = [];
  const calls = [];
  const timers = timerHarness();
  let now = NOW;
  let gate = null;
  let failed = false;
  let unsafe = false;
  let clockFailed = false;
  let grantReadFailsOnce = false;
  const $ = {
    command: { register: async spec => calls.push(["command", spec.name]) },
    clock: {
      now: async () => { if (clockFailed) throw new Error("synthetic-clock-error"); return now; },
      after: timers.after,
    },
    fs: {
      stat: async path => { calls.push(["stat", path]); return {
        kind: path === directory ? "dir" : "file", isLink: unsafe,
        realPath: path, size: (files.get(path) ?? "").length,
      }; },
      exists: async path => files.has(path),
      read: async path => {
        calls.push(["read", path]);
        if (grantReadFailsOnce && path.endsWith("/probe-grant.json")) {
          grantReadFailsOnce = false;
          throw new Error("synthetic-read-error");
        }
        return files.get(path);
      },
      write: async (path, text) => {
        writes.push([path, text]);
        if (gate) await gate;
        if (failed) throw new Error("synthetic-private-error");
        files.set(path, text);
      },
    },
  };
  register((name, matcher, handler) => {
    hooks.set(name, typeof matcher === "function" ? matcher : handler);
  });
  let nexts = 0;
  return { $, files, writes, calls, timers,
    time: value => { now = value; }, failClock: () => { clockFailed = true; },
    failNextGrantRead: () => { grantReadFailsOnce = true; },
    fail: () => { failed = true; }, unsafe: () => { unsafe = true; },
    gate: value => { gate = value; },
    command: (args, signal = new AbortController().signal) => hooks.get("command.run")(
      $, { command: "quotatempo-probe", args }, Object.assign(async e => e, { signal })),
    event: (name, value = {}) => hooks.get(name)($, value, async e => { nexts++; return e; }),
    nexts: () => nexts,
  };
}

function encryptedEnvelope(init) {
  const envelope = JSON.parse(init.body);
  assert.deepEqual(Object.keys(envelope).sort(), ["ciphertext", "connectionID", "enc", "requestID", "schemaVersion", "streamID"]);
  assert.equal(envelope.schemaVersion, 3);
  assert.equal(Object.hasOwn(envelope, "result"), false);
  assert.equal(Object.hasOwn(envelope, "sequence"), false);
  for (const marker of ['"rateLimits"', '"percentUsed"', '"resetsAt"', '"status"', '"readAt"', "synthetic-private"]) {
    assert.equal(init.body.includes(marker), false);
  }
  return envelope;
}

function unixHarness() {
  const h = harness({ directory: UNIX_DIRECTORY, grantValue: unixGrant });
  const requests = [];
  h.$.http = { fetch: async (url, init) => {
    assert.match(url, /^http:\/\/quotatempo\/(connect|measure|disconnect)$/);
    assert.deepEqual(Object.keys(init).sort(), ["body", "headers", "method", "socketPath"]);
    assert.equal(init.method, "POST");
    assert.equal(init.socketPath, unixGrant.socketPath);
    assert.deepEqual(init.headers, { "Content-Type": "application/json" });
    const opened = await openRequest(encryptedEnvelope(init), url.split("/").at(-1));
    requests.push({ url, init, body: opened.body });
    const status = { connect: "connected", measure: "accepted", disconnect: "disconnected" }[url.split("/").at(-1)];
    return { status: 200, ok: true, headers: {}, text: JSON.stringify(opened.reply(status)) };
  } };
  return { ...h, requests, connect: signal => h.command(`connect ${UNIX_DIRECTORY} ${TEST_PUBLIC_KEY}`, signal) };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const settle = () => new Promise(resolve => setImmediate(resolve));

test("already-aborted command is inert, including against an active connection", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  controller.abort();
  assert.match((await h.connect(controller.signal)).text, /cancelled/);
  assert.equal(h.calls.length, 0);
  await h.connect();
  assert.match((await h.command("disconnect", controller.signal)).text, /cancelled/);
  await h.event("session.measure", usage());
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/measure"]);
});

test("aborting an initial grant read prevents a late handshake or quota delivery", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  const entered = deferred();
  const late = deferred();
  const read = h.$.fs.read;
  h.$.fs.read = async path => { entered.resolve(); await late.promise; return read(path); };
  const connecting = h.connect(controller.signal);
  await entered.promise;
  controller.abort();
  await h.event("session.measure", usage());
  late.resolve();
  assert.match((await connecting).text, /cancelled/);
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 0);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
});

for (const stalledCleanup of [false, true]) {
  test(`aborted connect ignores authentic ACK and cleans up once${stalledCleanup ? " within a bounded uncertain wait" : ""}`, async () => {
    const h = unixHarness();
    const controller = new AbortController();
    const connectEntered = deferred();
    const disconnectEntered = deferred();
    const lateConnect = deferred();
    const lateDisconnect = deferred();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => {
      const reply = await fetch(...args);
      if (args[0].endsWith("/connect")) { connectEntered.resolve(); await lateConnect.promise; }
      if (stalledCleanup && args[0].endsWith("/disconnect")) {
        disconnectEntered.resolve(); await lateDisconnect.promise;
      }
      return reply;
    };
    const connecting = h.connect(controller.signal);
    await connectEntered.promise;
    controller.abort();
    await h.event("session.measure", usage());
    lateConnect.resolve();
    if (stalledCleanup) {
      await disconnectEntered.promise;
      await h.event("session.measure", usage());
      h.timers.advance(5_000);
    }
    const answer = await connecting;
    assert.equal(answer.text, stalledCleanup ? DISCONNECT_UNCONFIRMED
      : "Probe connection cancelled. No product source was changed.");
    lateDisconnect.resolve();
    await settle();
    await h.event("session.measure", usage());
    await h.command("disconnect");
    assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
    assert.deepEqual(h.requests[1].body, h.requests[0].body);
    assert.equal(h.writes.length, 0);
    assert.equal(h.timers.pending(), 0);
  });
}

test("aborting a superseded grant read cannot cancel the later connection generation", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  const entered = deferred();
  const late = deferred();
  const read = h.$.fs.read;
  let first = true;
  h.$.fs.read = async path => {
    if (first) { first = false; entered.resolve(); await late.promise; }
    return read(path);
  };
  const old = h.connect(controller.signal);
  await entered.promise;
  assert.match((await h.connect()).text, /Comparison-only probe connected/);
  controller.abort();
  late.resolve();
  assert.match((await old).text, /cancelled/);
  await h.event("session.measure", usage());
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/measure"]);
});

test("aborting a connect post preflight prevents its late HTTP send", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  const entered = deferred();
  const late = deferred();
  const read = h.$.fs.read;
  let reads = 0;
  h.$.fs.read = async path => {
    if (++reads === 2) { entered.resolve(); await late.promise; }
    return read(path);
  };
  const connecting = h.connect(controller.signal);
  await entered.promise;
  controller.abort();
  late.resolve();
  assert.match((await connecting).text, /cancelled/);
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 0);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
});

test("abandoned stalled connect and cleanup consume only two bounded waits", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  const connectEntered = deferred();
  const disconnectEntered = deferred();
  const late = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    (args[0].endsWith("/connect") ? connectEntered : disconnectEntered).resolve();
    await late.promise;
    return reply;
  };
  const connecting = h.connect(controller.signal);
  await connectEntered.promise;
  controller.abort();
  h.timers.advance(5_000);
  await disconnectEntered.promise;
  h.timers.advance(5_000);
  assert.equal((await connecting).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.timers.pending(), 0);
  late.resolve();
  await settle();
  await h.command("disconnect");
  await h.event("session.measure", usage());
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
  assert.equal(h.writes.length, 0);
});

test("connect removes its abort listener on completion and old signals leave later setups active", async () => {
  const h = unixHarness();
  const controller = new AbortController();
  const signal = controller.signal;
  const add = signal.addEventListener.bind(signal);
  const remove = signal.removeEventListener.bind(signal);
  const listeners = new Set();
  signal.addEventListener = (name, fn, options) => { listeners.add(fn); add(name, fn, options); };
  signal.removeEventListener = (name, fn) => { listeners.delete(fn); remove(name, fn); };
  await h.connect(signal);
  assert.equal(listeners.size, 0);
  await h.connect();
  controller.abort();
  await h.event("session.measure", usage());
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect", "/connect", "/measure"]);
});

test("abort at the verified ACK microtask boundary cannot leave an active connection", async () => {
  for (let depth = 0; depth < 12; depth++) {
    const h = unixHarness();
    const controller = new AbortController();
    const signal = controller.signal;
    const add = signal.addEventListener.bind(signal);
    const remove = signal.removeEventListener.bind(signal);
    let listening = false;
    let abandonedBeforeCompletion = false;
    signal.addEventListener = (...args) => { listening = true; add(...args); };
    signal.removeEventListener = (...args) => { listening = false; remove(...args); };
    const read = h.$.fs.read;
    let reads = 0;
    h.$.fs.read = async path => {
      if (++reads === 3) {
        let abandon = () => { abandonedBeforeCompletion = listening; controller.abort(); };
        for (let index = 0; index < depth; index++) {
          const next = abandon;
          abandon = () => queueMicrotask(next);
        }
        queueMicrotask(abandon);
      }
      return read(path);
    };
    await h.connect(signal);
    await settle();
    assert.equal(listening, false);
    await h.event("session.measure", usage());
    assert.equal(h.requests.filter(r => r.url.endsWith("/measure")).length,
      abandonedBeforeCompletion ? 0 : 1, `ACK boundary depth ${depth}`);
    assert.equal(h.writes.length, 0);
    assert.equal(h.timers.pending(), 0);
  }
});

test("each completed HPKE post cancels its deadline", async () => {
  const h = unixHarness();
  await h.connect();
  await h.event("session.measure", usage());
  await h.command("disconnect");
  assert.equal(h.timers.pending(), 0);
  assert.equal(h.timers.cancelled(), 3);
  h.timers.advance(50_000);
  await settle();
  assert.equal(h.requests.length, 3);
  assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
});

test("missing or throwing timer API fails closed before any HTTP or quota file write", async () => {
  for (const unavailable of [undefined, () => { throw new Error("synthetic-private-timer-error"); }]) {
    const h = unixHarness();
    h.$.clock.after = unavailable;
    const answer = await h.connect();
    assert.match(answer.text, /connection failed/);
    assert.equal(answer.text.includes("synthetic-private"), false);
    await h.event("session.measure", usage());
    await h.command("disconnect");
    assert.equal(h.requests.length, 0);
    assert.equal(h.writes.length, 0);
    assert.equal(h.timers.pending(), 0);
  }
});

for (const failure of ["missing", "throwing"]) {
  test(`${failure} clock.now refuses initial setup without HTTP, fallback or cached quota`, async () => {
    const h = unixHarness();
    const now = h.$.clock.now;
    h.$.clock.now = failure === "missing" ? undefined
      : async () => { throw new Error("synthetic-private-clock-error"); };
    const answer = await h.connect();
    assert.equal(answer.text, "Probe connection failed. Prepare a new private comparison directory; no product source was changed.");
    await h.event("session.measure", usage());
    h.$.clock.now = now;
    await h.event("session.measure", usage(80));
    await h.command("disconnect");
    assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
    assert.equal(h.requests.length, 0);
    assert.equal(h.writes.length, 0);
    assert.equal(h.timers.pending(), 0);
    assert.equal(h.timers.cancelled(), 0);
  });
}

test("losing clock.now after connect clears quota and recovery permits only explicit control", async () => {
  const h = unixHarness();
  await h.connect();
  const now = h.$.clock.now;
  h.$.clock.now = undefined;
  await h.event("session.measure", usage());
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  h.$.clock.now = now;
  await h.event("session.measure", usage(80));
  await h.command("disconnect");
  await h.command("disconnect");
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
  assert.deepEqual(h.requests[1].body, h.requests[0].body);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
});

test("losing clock.after after connect fails immediately without delivery or later quota replay", async () => {
  const h = unixHarness();
  await h.connect();
  const after = h.$.clock.after;
  h.$.clock.after = undefined;
  await h.event("session.measure", usage());
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.timers.pending(), 0);
  assert.equal(h.requests.length, 1);
  h.$.clock.after = after;
  await h.event("session.measure", usage(80));
  await h.command("disconnect");
  await h.command("disconnect");
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
  assert.deepEqual(h.requests[1].body, h.requests[0].body);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
  assert.equal(h.timers.cancelled(), 2);
});

test("missing command.register fails session setup without registering fallback or exporting quota", async () => {
  const h = unixHarness();
  h.$.command.register = undefined;
  await assert.rejects(h.event("session.start"), TypeError);
  assert.equal(h.nexts(), 0);
  await h.event("session.measure", usage());
  await h.event("session.measure", usage(80));
  assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
  assert.equal(h.calls.length, 0);
  assert.equal(h.requests.length, 0);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
});

test("stalled connect expires at 5000ms and late authentic ACK cannot activate or replay", async () => {
  const h = unixHarness();
  const entered = deferred();
  const late = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/connect")) { entered.resolve(); await late.promise; }
    return reply;
  };
  let finished = false;
  const connecting = h.connect().then(result => { finished = true; return result; });
  await entered.promise;
  h.timers.advance(4_999);
  await settle();
  assert.equal(finished, false);
  h.timers.advance(1);
  assert.match((await connecting).text, /connection failed/);
  assert.equal(h.timers.pending(), 0);
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  late.resolve();
  await settle();
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 1);
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.match((await h.command("disconnect")).text, /probe disconnected/);
  await h.command("disconnect");
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
  assert.deepEqual(h.requests[1].body, h.requests[0].body);
  assert.equal(h.writes.length, 0);
});

for (const ending of ["disconnect", "session.end", "session.start"]) {
  test(`stalled measure bounds ${ending}, drops queued quota and ignores late delivery`, async () => {
    const h = unixHarness();
    await h.connect();
    const entered = deferred();
    const late = deferred();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => {
      const reply = await fetch(...args);
      if (args[0].endsWith("/measure")) { entered.resolve(); await late.promise; }
      return reply;
    };
    const measuring = h.event("session.measure", usage());
    await entered.promise;
    const queued = h.event("session.measure", usage(60));
    let stopped = false;
    const stop = (ending === "disconnect" ? h.command(ending) : h.event(ending))
      .then(result => { stopped = true; return result; });
    const duplicate = h.command("disconnect");
    await settle();
    assert.equal(stopped, false);
    h.timers.advance(5_000);
    await Promise.all([measuring, queued, stop, duplicate]);
    assert.equal(stopped, true);
    assert.equal(h.timers.pending(), 0);
    assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/measure", "/disconnect"]);
    assert.deepEqual(h.requests[2].body, h.requests[0].body);
    assert.equal(h.requests[1].body.result.rateLimits[0].percentUsed, 42);
    late.resolve();
    await settle();
    await h.event("session.measure", usage(80));
    await h.command("disconnect");
    assert.equal(h.requests.length, 3);
    assert.equal(h.writes.length, 0);
    assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
  });
}

test("stalled measure fails closed even without an explicit stop", async () => {
  const h = unixHarness();
  await h.connect();
  const entered = deferred();
  const late = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/measure")) { entered.resolve(); await late.promise; }
    return reply;
  };
  const measuring = h.event("session.measure", usage());
  await entered.promise;
  const queued = h.event("session.measure", usage(60));
  await settle();
  h.timers.advance(5_000);
  await Promise.all([measuring, queued]);
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  late.resolve();
  await settle();
  await h.event("session.measure", usage(80));
  assert.equal(h.requests.length, 2);
  assert.match((await h.command("disconnect")).text, /probe disconnected/);
  assert.deepEqual(h.requests[2].body, h.requests[0].body);
  assert.equal(h.writes.length, 0);
});

for (const lateResult of ["reply", "reject"]) {
  test(`stalled disconnect stays unconfirmed after late ${lateResult} and is never retried`, async () => {
    const h = unixHarness();
    await h.connect();
    const entered = deferred();
    const late = deferred();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => {
      const reply = await fetch(...args);
      if (args[0].endsWith("/disconnect")) { entered.resolve(); await late.promise; }
      return reply;
    };
    const closing = h.command("disconnect");
    await entered.promise;
    const duplicate = h.command("disconnect");
    h.timers.advance(5_000);
    assert.equal((await closing).text, DISCONNECT_UNCONFIRMED);
    assert.equal((await duplicate).text, DISCONNECT_UNCONFIRMED);
    assert.equal(h.timers.pending(), 0);
    if (lateResult === "reply") late.resolve();
    else late.reject(new Error("synthetic-late-error"));
    await settle();
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
    assert.equal((await h.command("disconnect")).text, DISCONNECT_UNCONFIRMED);
    await h.event("session.measure", usage());
    assert.equal(h.requests.length, 2);
    assert.equal(h.writes.length, 0);
  });
}

test("stop spends at most two bounded post waits, not an unfinished host promise", async () => {
  const h = unixHarness();
  const connectEntered = deferred();
  const disconnectEntered = deferred();
  const late = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    (args[0].endsWith("/connect") ? connectEntered : disconnectEntered).resolve();
    await late.promise;
    return reply;
  };
  const connecting = h.connect();
  await connectEntered.promise;
  const closing = h.command("disconnect");
  await settle();
  h.timers.advance(5_000);
  assert.match((await connecting).text, /connection failed/);
  await disconnectEntered.promise;
  h.timers.advance(5_000);
  assert.equal((await closing).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.timers.pending(), 0);
  late.resolve();
  await settle();
  await h.command("disconnect");
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 2);
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.writes.length, 0);
});

test("deadline during post preflight cannot send a late measurement", async () => {
  const h = unixHarness();
  await h.connect();
  const entered = deferred();
  const late = deferred();
  const read = h.$.fs.read;
  let stalled = true;
  h.$.fs.read = async path => {
    if (stalled) { stalled = false; entered.resolve(); await late.promise; }
    return read(path);
  };
  const measuring = h.event("session.measure", usage());
  await entered.promise;
  h.timers.advance(5_000);
  await measuring;
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.requests.length, 1);
  late.resolve();
  await settle();
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 1);
  assert.match((await h.command("disconnect")).text, /probe disconnected/);
  assert.equal(h.writes.length, 0);
});

function stickyUnixHarness() {
  const h = unixHarness();
  const freshDirectory = `/private/tmp/qtc-${STREAM}`;
  const freshGrant = { ...unixGrant, connectionID: OTHER, socketPath: `${freshDirectory}/bridge.sock` };
  h.files.set(`${freshDirectory}/probe-grant.json`, JSON.stringify(freshGrant));
  const stat = h.$.fs.stat;
  h.$.fs.stat = async path => ({ ...await stat(path),
    kind: path === freshDirectory || path === UNIX_DIRECTORY ? "dir" : "file" });
  const servers = new Map();
  h.$.http.fetch = async (url, init) => {
    const opened = await openRequest(encryptedEnvelope(init), new URL(url).pathname.slice(1));
    const { body } = opened;
    h.requests.push({ url, init, body });
    const server = servers.get(init.socketPath) ?? { streamID: null, disconnected: false, result: null };
    servers.set(init.socketPath, server);
    const endpoint = new URL(url).pathname;
    if (endpoint === "/connect") {
      if (server.disconnected || server.streamID && server.streamID !== body.streamID) {
        return { status: 409, ok: false, text: '{"status":"rejected"}' };
      }
      server.streamID = body.streamID;
    } else {
      assert.equal(body.streamID, server.streamID);
      if (endpoint === "/disconnect") { server.disconnected = true; server.result = null; }
      else { assert.equal(server.disconnected, false); server.result = body.result; }
    }
    return { status: 200, ok: true, text: JSON.stringify(opened.reply(
      { "/connect": "connected", "/measure": "accepted", "/disconnect": "disconnected" }[endpoint])) };
  };
  return { ...h, servers, freshDirectory,
    freshConnect: () => h.command(`connect ${freshDirectory} ${TEST_PUBLIC_KEY}`) };
}

test("schema 3 grants require exact keys and the selected restricted qtc socket", () => {
  assert(decodeGrant(JSON.stringify(unixGrant), NOW, UNIX_DIRECTORY));
  assert.equal(decodeGrant(JSON.stringify(unixGrant), NOW), null);
  for (const value of [
    { ...unixGrant, extra: true }, { ...unixGrant, transport: "tcp" },
    { ...unixGrant, schemaVersion: 2 }, { ...unixGrant, connectionID: "bad" },
    { ...unixGrant, transport: "unix-http" }, { ...unixGrant, publicKey: TEST_PUBLIC_KEY },
    { ...unixGrant, createdAt: "2026-10-06T00:00:00Z" },
    { ...unixGrant, socketPath: `${UNIX_DIRECTORY}/other.sock` },
    { ...unixGrant, socketPath: `/private/tmp/qtc-${STREAM}/bridge.sock` },
    { ...unixGrant, socketPath: "/tmp/bridge.sock" },
    { ...unixGrant, socketPath: "http://localhost:1234" },
    { ...unixGrant, socketPath: null },
    { schemaVersion: 3, purpose: grant.purpose, connectionID: CONNECTION, createdAt: T0 },
  ]) assert.equal(decodeGrant(JSON.stringify(value), NOW, UNIX_DIRECTORY), null);
  for (const directory of ["/tmp/qtc-" + OTHER, "/private/tmp/arbitrary", UNIX_DIRECTORY + "/",
    UNIX_DIRECTORY + "/..", "/private/tmp/qtc-11111111-1111-1111-8111-111111111111"]) {
    const value = { ...unixGrant, socketPath: `${directory}/bridge.sock` };
    assert.equal(decodeGrant(JSON.stringify(value), NOW, directory), null);
  }
  assert.equal(decodeGrant(JSON.stringify(unixGrant), NOW + 900_001, UNIX_DIRECTORY), null);
  assert.equal(decodeGrant(JSON.stringify(unixGrant), NOW - 5001, UNIX_DIRECTORY), null);
});

test("Unix HPKE handshake precedes encrypted schema 1 measures and schema 2 disconnect", async () => {
  const h = unixHarness();
  const connected = await h.connect();
  assert.match(connected.text, /Comparison-only/);
  assert.equal(h.requests.length, 1);
  const id = h.requests[0].body.streamID;
  assert.deepEqual(h.requests[0].body, { schemaVersion: 2, connectionID: CONNECTION, streamID: id });
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  await h.event("session.measure", { ...usage(), auth: "synthetic-private", model: "synthetic-private", context: "synthetic-private" });
  const body = h.requests[1].body;
  assert.deepEqual(Object.keys(body).sort(), ["connectionID", "result", "schemaVersion", "sequence", "streamID"]);
  assert.equal(body.schemaVersion, 1);
  assert.equal(body.sequence, 1);
  assert.equal(body.streamID, id);
  assert.equal(body.result.rateLimits[0].percentUsed, 42);
  assert.equal(h.requests[1].init.body.includes("synthetic-private"), false);
  await h.command("disconnect");
  assert.deepEqual(h.requests[2].body, h.requests[0].body);
  assert.notEqual(h.requests[2].init.body, h.requests[0].init.body);
  assert.equal(new Set(h.requests.map(r => JSON.parse(r.init.body).requestID)).size, 3);
  assert.deepEqual(h.requests.map(r => r.url), ["http://quotatempo/connect", "http://quotatempo/measure", "http://quotatempo/disconnect"]);
  assert.equal(h.writes.length, 0);
  assert(h.calls.filter(([kind]) => kind === "read").every(([, path]) => path === `${UNIX_DIRECTORY}/probe-grant.json`));
  const count = h.requests.length;
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, count);
});

test("Unix HPKE requires the copied public-key pin and refuses an altered pin without plaintext", async () => {
  for (const pin of ["", "abcd", TEST_PUBLIC_KEY.toUpperCase(), "00".repeat(32), "09" + "00".repeat(31)]) {
    const h = unixHarness();
    const sent = [];
    h.$.http.fetch = async (url, init) => {
      const envelope = encryptedEnvelope(init);
      sent.push({ url, init });
      await assert.rejects(openRequest(envelope, new URL(url).pathname.slice(1)));
      return { status: 200, ok: true, text: '{"status":"connected"}' };
    };
    assert.match((await h.command(`connect ${UNIX_DIRECTORY} ${pin}`)).text, /failed/);
    await h.event("session.measure", usage());
    await h.event("session.measure", usage(80));
    assert(sent.length <= 1);
    assert.equal(h.writes.length, 0);
    assert.equal(h.nexts(), 2);
  }
});

for (const phase of ["before", "after"]) {
  test(`Unix HPKE key replacement ${phase} connect cannot replace the command pin or export quota`, async () => {
    const h = unixHarness();
    if (phase === "after") assert.match((await h.connect()).text, /Comparison-only/);
    h.files.set(`${UNIX_DIRECTORY}/probe-grant.json`, JSON.stringify({ ...unixGrant, publicKey: "09" + "00".repeat(31) }));
    if (phase === "before") assert.match((await h.connect()).text, /failed/);
    await h.event("session.measure", usage());
    await h.event("session.measure", usage(80));
    await h.command("disconnect");
    assert.equal(h.requests.length, phase === "after" ? 1 : 0);
    assert.equal(h.writes.length, 0);
    assert.equal((await h.command("status")).text, phase === "after" ? DISCONNECT_UNCONFIRMED : "QuotaTempo probe disconnected.");
  });

  for (const attack of ["fake endpoint", "forged proof", "replayed proof"]) {
    test(`Unix HPKE rejects ${attack} ${phase} connect with only ciphertext and no fallback`, async () => {
      const h = unixHarness();
      const fetch = h.$.http.fetch;
      let captured;
      let previous;
      if (attack === "replayed proof" && phase === "before") {
        const earlier = unixHarness();
        const earlierFetch = earlier.$.http.fetch;
        earlier.$.http.fetch = async (...args) => { previous = await earlierFetch(...args); return previous; };
        await earlier.connect();
      }
      if (phase === "after") {
        assert.match((await h.connect()).text, /Comparison-only/);
        if (attack === "replayed proof") {
          h.$.http.fetch = async (...args) => { previous = await fetch(...args); return previous; };
          await h.event("session.measure", usage());
          assert.equal(h.requests.at(-1).body.result.status, "valid");
        }
      }
      const count = h.requests.length;
      h.$.http.fetch = async (url, init) => {
        const envelope = encryptedEnvelope(init);
        captured = envelope;
        if (attack === "fake endpoint") {
          h.requests.push({ url, init });
          await assert.rejects(openRequest(envelope, "disconnect"));
          return { status: 200, ok: true, text: JSON.stringify({ status: phase === "before" ? "connected" : "accepted" }) };
        }
        const response = await fetch(url, init);
        const reply = JSON.parse(attack === "replayed proof" ? previous.text : response.text);
        // Match the new request ID so the MAC, not only ID equality, rejects replay.
        reply.requestID = envelope.requestID;
        if (attack === "forged proof") reply.proof = (reply.proof[0] === "0" ? "1" : "0") + reply.proof.slice(1);
        return { ...response, text: JSON.stringify(reply) };
      };
      if (phase === "before") assert.match((await h.connect()).text, /failed/);
      else await h.event("session.measure", usage(60));
      assert(captured);
      assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
      await h.event("session.measure", usage(80));
      await h.event("session.measure", usage(90));
      assert.equal(h.requests.length, count + 1);
      assert.equal(h.writes.length, 0);
    });
  }
}

test("failed and malformed Unix handshakes never activate, export or fall back", async () => {
  const replies = [
    { status: 503, ok: false, text: '{"status":"connected"}' },
    { status: 201, ok: true, text: '{"status":"connected"}' },
    { status: 200, ok: false, text: '{"status":"connected"}' },
    ...["{", "null", "[]", '{"status":"accepted"}', '{"status":"connected","extra":true}',
      '"connected"', "x".repeat(1025), undefined].map(text => ({ status: 200, ok: true, text })),
    new Error("synthetic-private-error"),
  ];
  for (const reply of replies) {
    const h = unixHarness();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => { await fetch(...args); if (reply instanceof Error) throw reply; return reply; };
    assert.match((await h.connect()).text, /failed/);
    await h.event("session.measure", usage());
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
    assert.equal(h.requests.length, 1);
    assert.equal(h.writes.length, 0);
  }
});

test("schema 3 with missing or unavailable HTTP API never falls back to files or TCP", async () => {
  for (const api of [undefined, {}, { fetch: null }, { fetch: async () => { throw new Error("synthetic-private-error"); } }]) {
    const h = unixHarness();
    h.$.http = api;
    const response = await h.connect();
    assert.match(response.text, /failed/);
    assert.equal(response.text.includes("synthetic-private-error"), false);
    await h.event("session.measure", usage());
    await h.event("session.measure", usage(80));
    await h.command("disconnect");
    await h.command("disconnect");
    assert.equal(h.writes.length, 0);
    assert.equal(h.requests.length, 0);
    assert.equal(h.timers.pending(), 0);
  }
});

test("losing http.fetch after connect cancels the deadline and never replays quota on recovery", async () => {
  const h = unixHarness();
  await h.connect();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = undefined;
  await h.event("session.measure", usage());
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.timers.pending(), 0);
  assert.equal(h.timers.cancelled(), 2);
  h.$.http.fetch = fetch;
  await h.event("session.measure", usage(80));
  await h.command("disconnect");
  await h.command("disconnect");
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect"]);
  assert.deepEqual(h.requests[1].body, h.requests[0].body);
  assert.equal(h.writes.length, 0);
  assert.equal(h.timers.pending(), 0);
});

for (const phase of ["before", "after"]) {
  test(`runtime rejecting socketPath ${phase} connect stops safely without TCP, files or quota replay`, async () => {
    const h = unixHarness();
    if (phase === "after") await h.connect();
    const fetch = h.$.http.fetch;
    const attempted = [];
    h.$.http.fetch = async (url, init) => {
      assert.equal(init.socketPath, unixGrant.socketPath);
      attempted.push({ endpoint: new URL(url).pathname, envelope: encryptedEnvelope(init) });
      throw new Error("synthetic-private-socketPath-unsupported");
    };
    if (phase === "before") {
      assert.equal((await h.connect()).text,
        "Probe connection failed. Prepare a new private comparison directory; no product source was changed.");
    }
    await h.event("session.measure", usage());
    await h.event("session.measure", usage(80));
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
    assert.equal(h.timers.pending(), 0);
    assert.equal((await h.command("disconnect")).text, DISCONNECT_UNCONFIRMED);
    await h.command("disconnect");
    assert.deepEqual(attempted.map(r => r.endpoint), [phase === "before" ? "/connect" : "/measure", "/disconnect"]);
    assert.equal(new Set(attempted.map(r => r.envelope.requestID)).size, 2);
    h.$.http.fetch = fetch;
    await h.event("session.measure", usage(90));
    await h.command("disconnect");
    assert.equal(attempted.length, 2);
    assert.equal(h.requests.length, phase === "before" ? 0 : 1);
    assert.equal(h.writes.length, 0);
    assert.equal(h.timers.pending(), 0);
  });
}

test("immutable Unix grants are checked before every outgoing request", async () => {
  for (const mutate of [
    h => h.files.delete(`${UNIX_DIRECTORY}/probe-grant.json`),
    h => h.files.set(`${UNIX_DIRECTORY}/probe-grant.json`, JSON.stringify({ ...unixGrant, connectionID: STREAM })),
    h => h.files.set(`${UNIX_DIRECTORY}/probe-grant.json`, JSON.stringify(unixGrant) + " "),
    h => h.files.set(`${UNIX_DIRECTORY}/probe-grant.json`, JSON.stringify(grant)),
    h => h.unsafe(),
  ]) {
    const h = unixHarness();
    await h.connect();
    mutate(h);
    await h.event("session.measure", usage());
    await h.command("disconnect");
    assert.equal(h.requests.length, 1);
    assert.equal(h.writes.length, 0);
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  }
  const h = unixHarness();
  await h.connect();
  h.files.delete(`${UNIX_DIRECTORY}/probe-grant.json`);
  await h.command("disconnect");
  assert.equal(h.requests.length, 1);
});

test("a grant changed during handshake cannot become active or receive quota", async () => {
  const h = unixHarness();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    h.files.set(`${UNIX_DIRECTORY}/probe-grant.json`, JSON.stringify(grant));
    return reply;
  };
  assert.match((await h.connect()).text, /failed/);
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 1);
  assert.equal(h.writes.length, 0);
});

test("cancelled successful handshakes drain before disconnect, end, reload or a fresh grant", { timeout: 2000 }, async () => {
  for (const cancel of [h => h.command("disconnect"), h => h.event("session.end"),
    h => h.event("session.start"), h => h.freshConnect()]) {
    const h = stickyUnixHarness();
    const gate = deferred();
    const entered = deferred();
    const disconnectGate = deferred();
    const disconnectEntered = deferred();
    const fetch = h.$.http.fetch;
    let first = true;
    h.$.http.fetch = async (...args) => {
      const reply = await fetch(...args);
      if (first) { first = false; entered.resolve(); await gate.promise; }
      if (args[0].endsWith("/disconnect")) { disconnectEntered.resolve(); await disconnectGate.promise; }
      return reply;
    };
    const connecting = h.connect();
    await entered.promise;
    assert.match((await h.command("status")).text, /disconnected/);
    await h.event("session.measure", usage());
    assert.equal(h.requests.length, 1);
    let finished = false;
    const cancelling = cancel(h).then(result => { finished = true; return result; });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(finished, false);
    assert.equal(h.requests.length, 1);
    gate.resolve();
    await disconnectEntered.promise;
    assert.equal(finished, false);
    assert.equal(h.requests.length, 2);
    disconnectGate.resolve();
    assert.match((await connecting).text, /cancelled/);
    const newer = await cancelling;
    const closing = h.requests[1];
    assert.equal(closing.url, "http://quotatempo/disconnect");
    assert.deepEqual(closing.body, h.requests[0].body);
    if (newer.text?.includes("Stream:")) {
      assert.match((await h.command("status")).text, new RegExp(h.requests[2].body.streamID));
      assert.equal(h.requests[2].init.socketPath, `${h.freshDirectory}/bridge.sock`);
      assert.notEqual(closing.body.streamID, h.requests[2].body.streamID);
    } else assert.match((await h.command("status")).text, /disconnected/);
    assert.equal(h.writes.length, 0);
    assert.equal(h.servers.get(unixGrant.socketPath).disconnected, true);
  }
});

test("disconnect awaits late pending measure and disconnect reply, dropping queued quota", { timeout: 2000 }, async () => {
  const h = unixHarness();
  await h.connect();
  const measure = deferred();
  const measured = deferred();
  const disconnect = deferred();
  const disconnecting = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/measure")) { measured.resolve(); await measure.promise; }
    if (args[0].endsWith("/disconnect")) { disconnecting.resolve(); await disconnect.promise; }
    return reply;
  };
  const pending = h.event("session.measure", usage());
  await measured.promise;
  const later = h.event("session.measure", usage(60));
  let closed = false;
  const closing = h.command("disconnect").then(() => { closed = true; });
  const secondClose = h.command("disconnect");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(closed, false);
  assert.equal(h.requests.length, 2);
  measure.resolve();
  await disconnecting.promise;
  assert.equal(closed, false);
  disconnect.resolve();
  await Promise.all([pending, later, closing, secondClose]);
  assert.equal(closed, true);
  assert.equal(h.requests.length, 3);
  assert.equal(h.writes.length, 0);
});

test("cancelled handshake cleanup survives a transient grant-check failure without retrying disconnect", { timeout: 2000 }, async () => {
  const h = unixHarness();
  const entered = deferred();
  const gate = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/connect")) {
      entered.resolve();
      await gate.promise;
      h.failNextGrantRead();
    }
    return reply;
  };
  const connecting = h.connect();
  await entered.promise;
  const closing = h.command("disconnect");
  gate.resolve();
  assert.match((await connecting).text, /failed/);
  assert.match((await closing).text, /probe disconnected/);
  assert.deepEqual(h.requests.map(r => r.url), ["http://quotatempo/connect", "http://quotatempo/disconnect"]);
  assert.equal(h.writes.length, 0);
});

test("failed cancellation disconnect stays unconfirmed while a fresh connect changes generation", { timeout: 2000 }, async () => {
  const h = stickyUnixHarness();
  const gate = deferred();
  const entered = deferred();
  const fetch = h.$.http.fetch;
  let first = true;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (first) { first = false; entered.resolve(); await gate.promise; }
    if (args[0].endsWith("/disconnect")) throw new Error("synthetic-private-error");
    return reply;
  };
  const connecting = h.connect();
  await entered.promise;
  const newer = h.freshConnect();
  gate.resolve();
  const cancelled = await connecting;
  assert.equal(cancelled.text, DISCONNECT_UNCONFIRMED);
  assert.equal(cancelled.text.includes("synthetic-private-error"), false);
  assert.equal(h.requests.filter(r => r.url.endsWith("/disconnect")).length, 1);
  assert.match((await newer).text, /connected/);
  assert.match((await h.command("status")).text, new RegExp(h.requests[2].body.streamID));
  assert.equal(h.writes.length, 0);
});

test("Unix measurement errors stop without retries, raw errors, file writes or fallback", async () => {
  for (const reply of [new Error("synthetic-private-error"),
    { status: 500, ok: false, text: '{"status":"accepted"}' },
    { status: 200, ok: true, text: '{"status":"accepted","extra":true}' },
    { status: 200, ok: true, text: '{"status":"connected"}' }]) {
    const h = unixHarness();
    await h.connect();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => { await fetch(...args); if (reply instanceof Error) throw reply; return reply; };
    await h.event("session.measure", usage());
    await h.event("session.measure", usage());
    const status = await h.command("status");
    assert.equal(status.text, DISCONNECT_UNCONFIRMED);
    assert.equal(status.text.includes("synthetic-private-error"), false);
    assert.equal(h.requests.length, 2);
    assert.equal(h.writes.length, 0);
    assert.equal(h.nexts(), 2);
  }
});

test("Unix clock and disconnect failures keep fixed output and never invalidate via files", async () => {
  const h = unixHarness();
  await h.connect();
  h.failClock();
  await h.event("session.measure", usage());
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.equal(h.requests.length, 1);
  assert.equal(h.writes.length, 0);
  for (const reply of [new Error("synthetic-private-error"),
    { status: 201, ok: true, text: '{"status":"disconnected"}' },
    { status: 200, ok: true, text: '{"status":"disconnected","extra":true}' }]) {
    const h = unixHarness();
    await h.connect();
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => { await fetch(...args); if (reply instanceof Error) throw reply; return reply; };
    const response = await h.command("disconnect");
    assert.equal(response.text, DISCONNECT_UNCONFIRMED);
    assert.equal((await h.command("disconnect")).text, DISCONNECT_UNCONFIRMED);
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
    await h.event("session.measure", usage());
    assert.equal(h.requests.length, 2);
    assert.equal(h.writes.length, 0);
  }
});

test("Unix dead binding permits explicit control after clock or uncertain export failure, never quota replay", async () => {
  for (const failure of ["clock", "export", "grant_read"]) {
    const h = stickyUnixHarness();
    await h.connect();
    await h.event("session.measure", usage());
    const fetch = h.$.http.fetch;
    h.$.http.fetch = async (...args) => {
      const reply = await fetch(...args);
      if (failure === "export" && args[0].endsWith("/measure")) throw new Error("synthetic-private-error");
      return reply;
    };
    if (failure === "clock") h.failClock();
    if (failure === "grant_read") h.failNextGrantRead();
    await h.event("session.measure", usage(60));
    assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
    const measures = h.requests.filter(r => r.url.endsWith("/measure")).length;
    await h.event("session.measure", usage(80));
    assert.equal(h.requests.filter(r => r.url.endsWith("/measure")).length, measures);
    assert.equal((await h.command("disconnect")).text, "QuotaTempo probe disconnected. No product source was changed.");
    assert.equal(h.servers.get(unixGrant.socketPath).result, null);
    assert.deepEqual(h.requests.at(-1).body, h.requests[0].body);
    await h.command("disconnect");
    await h.event("session.end");
    await h.event("session.measure", usage(90));
    assert.equal(h.requests.filter(r => r.url.endsWith("/disconnect")).length, 1);
    assert.equal(h.requests.filter(r => r.url.endsWith("/measure")).length, measures);
    assert.equal(h.writes.length, 0);
    // The native bridge is sticky: a disconnected grant is not a reusable connection.
    if (failure !== "clock") {
      assert.match((await h.connect()).text, /failed/);
      assert.match((await h.freshConnect()).text, /Comparison-only probe connected/);
    }
  }
});

test("Unix clock failure drains a late export before explicit control clears the receiver", { timeout: 2000 }, async () => {
  const h = stickyUnixHarness();
  await h.connect();
  const entered = deferred();
  const gate = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/measure")) { entered.resolve(); await gate.promise; }
    return reply;
  };
  const exporting = h.event("session.measure", usage());
  await entered.promise;
  h.failClock();
  const failing = h.event("session.measure", usage(60));
  await new Promise(resolve => setImmediate(resolve));
  let closed = false;
  const closing = h.command("disconnect").then(result => { closed = true; return result; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(closed, false);
  assert.equal(h.requests.length, 2);
  gate.resolve();
  await Promise.all([exporting, failing]);
  assert.match((await closing).text, /probe disconnected/);
  assert.equal(h.servers.get(unixGrant.socketPath).result, null);
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/measure", "/disconnect"]);
  assert.equal(h.writes.length, 0);
});

test("Unix uncertain handshake retains only explicit disconnect control", async () => {
  const h = stickyUnixHarness();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/connect")) throw new Error("synthetic-private-error");
    return reply;
  };
  assert.match((await h.connect()).text, /failed/);
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 1);
  assert.equal((await h.command("status")).text, DISCONNECT_UNCONFIRMED);
  assert.match((await h.command("disconnect")).text, /probe disconnected/);
  assert.equal(h.servers.get(unixGrant.socketPath).disconnected, true);
  assert.equal(h.requests.length, 2);
  assert.equal(h.writes.length, 0);
});

test("Unix export failure during drain cannot lose disconnect control or replay quota", { timeout: 2000 }, async () => {
  const h = stickyUnixHarness();
  await h.connect();
  const entered = deferred();
  const gate = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/measure")) {
      entered.resolve();
      await gate.promise;
      throw new Error("synthetic-private-error");
    }
    return reply;
  };
  const exporting = h.event("session.measure", usage());
  await entered.promise;
  const closing = h.command("disconnect");
  gate.resolve();
  await exporting;
  assert.match((await closing).text, /probe disconnected/);
  await h.event("session.measure", usage(80));
  await h.command("disconnect");
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/measure", "/disconnect"]);
  assert.equal(h.servers.get(unixGrant.socketPath).result, null);
  assert.equal(h.writes.length, 0);
});

test("Unix cancelled handshake reports failed disconnect confirmation without retry or false success", { timeout: 2000 }, async () => {
  const h = stickyUnixHarness();
  const entered = deferred();
  const gate = deferred();
  const fetch = h.$.http.fetch;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (args[0].endsWith("/connect")) { entered.resolve(); await gate.promise; }
    if (args[0].endsWith("/disconnect")) return { ...reply, text: '{"status":"disconnected","extra":true}' };
    return reply;
  };
  const connecting = h.connect();
  await entered.promise;
  const closing = h.command("disconnect");
  const second = h.command("disconnect");
  gate.resolve();
  for (const result of await Promise.all([connecting, closing, second])) assert.equal(result.text, DISCONNECT_UNCONFIRMED);
  assert.equal((await h.command("disconnect")).text, DISCONNECT_UNCONFIRMED);
  await h.event("session.end");
  await h.event("session.start");
  await h.event("session.measure", usage());
  assert.equal(h.requests.length, 2);
  assert.equal(h.writes.length, 0);
});

test("Unix multiple newer connects fence a pending handshake without self-wait or stale activation", { timeout: 2000 }, async () => {
  const h = stickyUnixHarness();
  const entered = deferred();
  const gate = deferred();
  const fetch = h.$.http.fetch;
  let first = true;
  h.$.http.fetch = async (...args) => {
    const reply = await fetch(...args);
    if (first) { first = false; entered.resolve(); await gate.promise; }
    return reply;
  };
  const connecting = h.connect();
  await entered.promise;
  const superseded = h.freshConnect();
  const latest = h.freshConnect();
  gate.resolve();
  assert.match((await connecting).text, /cancelled/);
  assert.match((await superseded).text, /cancelled/);
  assert.match((await latest).text, /Comparison-only probe connected/);
  assert.deepEqual(h.requests.map(r => new URL(r.url).pathname), ["/connect", "/disconnect", "/connect"]);
  assert.equal(h.requests[2].init.socketPath, `${h.freshDirectory}/bridge.sock`);
  assert.match((await h.command("status")).text, new RegExp(h.requests[2].body.streamID));
  assert.equal(h.writes.length, 0);
});

test("comparison maps usage into W without granting freshness, ownership or planning", async () => {
  const result = receiver().consume(JSON.stringify(await message()), NOW);
  assert.equal(result.weekly.remainingPercent, 58);
  assert.equal(result.weekly.resetAt, WEEK);
  assert.equal(result.fiveHour, null);
  assert.equal(result.status, "comparison_only");
  assert.equal(result.sourceCapturedAt, null);
  assert.equal(result.identity, "unverified");
  assert.equal(result.automaticSelectionEligible, false);
  assert.equal(result.planningEligible, false);
});

test("connections and streams never merge, and sequences reject replay", async () => {
  const m = await message();
  const r = receiver();
  for (const field of ["streamID", "connectionID"]) {
    assert.equal(r.consume(JSON.stringify({ ...m, [field]: OTHER }), NOW).weekly, null);
  }
  assert.equal(r.consume(JSON.stringify(m), NOW).weekly.remainingPercent, 58);
  assert.equal(r.consume(JSON.stringify(m), NOW).status, "invalid_message");
  assert.equal(r.consume(JSON.stringify({ ...m, sequence: 2 }), NOW).status, "comparison_only");
});

test("partial JSON, extra fields, oversized input and unsafe sequences are rejected", async () => {
  const m = await message();
  const malformed = ["{", "null", "[]", "x".repeat(MAX_BYTES + 1),
    JSON.stringify({ ...m, account: "synthetic" }),
    JSON.stringify({ ...m, schemaVersion: 2 }),
    JSON.stringify({ ...m, result: { ...m.result, account: "synthetic" } }),
  ];
  for (const sequence of [0, -1, 1.5, "1", Number.MAX_SAFE_INTEGER + 1]) {
    malformed.push(JSON.stringify({ ...m, sequence }));
  }
  for (const input of malformed) assert.equal(receiver().consume(input, NOW).weekly, null);
  const extended = JSON.parse(JSON.stringify(m));
  extended.result.rateLimits[0].extra = "synthetic";
  assert.equal(receiver().consume(JSON.stringify(extended), NOW).weekly, null);
});

test("unchanged reads cannot renew the five-minute comparison age", async () => {
  let current = T0;
  let output;
  const p = createUsageProducer({ getUsage: usage, clock: () => current, sink: value => { output = value; } });
  await p.poll();
  current = new Date(NOW + 301_000).toISOString();
  await p.poll();
  const r = receiver().consume(encodeMessage({ connectionID: CONNECTION, streamID: STREAM,
    sequence: 2, result: output }), NOW + 301_000);
  assert.equal(r.status, "stale");
  assert.equal(r.weekly, null);
});

test("passed resets, future reads, impossible horizons and clock rollback withhold values", async () => {
  const atReset = await message(usage(42, new Date(NOW + 60_000).toISOString()));
  assert.equal(receiver().consume(JSON.stringify(atReset), NOW + 60_000).status, "reset_passed");
  const future = await message(usage(), new Date(NOW + 6000).toISOString());
  assert.equal(receiver().consume(JSON.stringify(future), NOW).weekly, null);
  const far = await message(usage(42, "2400-01-01T00:00:00.000Z"));
  assert.equal(receiver().consume(JSON.stringify(far), NOW).weekly, null);
  const r = receiver();
  r.consume(JSON.stringify(await message()), NOW);
  assert.equal(r.consume(JSON.stringify(await message()), NOW - 1).status, "invalid_clock");
});

test("empty, missing-reset, unknown-model and API-key-like readings clear comparison values", async () => {
  for (const input of [ { rateLimits: [] }, { rateLimits: [{ kind: "seven_day", percentUsed: 2 }] },
    { rateLimits: [{ kind: "seven_day_fable", percentUsed: 2, resetsAt: WEEK }] } ]) {
    const r = receiver();
    r.consume(JSON.stringify(await message()), NOW);
    assert.equal(r.consume(JSON.stringify(await message(input, T0, 2)), NOW).weekly, null);
  }
  const onlyShort = { rateLimits: [{ kind: "five_hour", percentUsed: 5, resetsAt: new Date(NOW + 18_000_000).toISOString() }] };
  const result = receiver().consume(JSON.stringify(await message(onlyShort)), NOW);
  assert.equal(result.weekly, null);
  assert.equal(result.fiveHour.remainingPercent, 95);
});

test("grants require a strict metadata schema and a fifteen-minute connect deadline", () => {
  assert(decodeGrant(JSON.stringify(grant), NOW));
  for (const value of [{ ...grant, account: "synthetic" }, { ...grant, connectionID: "bad" },
    { ...grant, purpose: "other" }, { ...grant, createdAt: "2026-02-30T00:00:00.000Z" }]) {
    assert.equal(decodeGrant(JSON.stringify(value), NOW), null);
  }
  assert.equal(decodeGrant(JSON.stringify(grant), NOW + 900_001), null);
  assert.equal(decodeGrant(JSON.stringify(grant), NOW - 5001), null);
});

test("revoking or replacing the app grant prevents further exports", async () => {
  for (const replacement of [null, JSON.stringify({ ...grant, connectionID: OTHER })]) {
    const h = harness();
    await h.command(`connect ${DIRECTORY}`);
    if (replacement === null) h.files.delete(`${DIRECTORY}/probe-grant.json`);
    else h.files.set(`${DIRECTORY}/probe-grant.json`, replacement);
    await h.event("session.measure", usage());
    assert.equal(h.writes.length, 0);
    assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
  }
});

test("the grant deadline limits connecting, not an already connected stream", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  h.time(NOW + 901_000);
  await h.event("session.measure", usage());
  assert.equal(h.writes.length, 1);
  assert.equal(JSON.parse(h.writes[0][1]).result.status, "valid");
});

test("clock failure invalidates an existing export without relying on another clock read", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  await h.event("session.measure", usage());
  h.failClock();
  await h.event("session.measure", usage());
  assert.equal(h.writes.length, 2);
  const last = JSON.parse(h.writes[1][1]).result;
  assert.equal(last.reason, "clock_failed");
  assert.equal(last.readAt, null);
  assert.deepEqual(last.rateLimits, []);
  assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
});

test("disconnect invalidation is independent of a failed clock", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  await h.event("session.measure", usage());
  h.failClock();
  await h.command("disconnect");
  assert.equal(JSON.parse(h.writes.at(-1)[1]).result.reason, "disconnected");
  assert.equal(JSON.parse(h.writes.at(-1)[1]).result.readAt, null);
});

test("one failed grant read invalidates the old value without retrying quota delivery", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  await h.event("session.measure", usage());
  h.failNextGrantRead();
  await h.event("session.measure", usage());
  assert.equal(h.writes.length, 2);
  const result = JSON.parse(h.writes[1][1]).result;
  assert.equal(result.reason, "export_failed");
  assert.deepEqual(result.rateLimits, []);
  assert.equal((await h.command("status")).text, "QuotaTempo probe disconnected.");
});

test("load and unconnected events do not read usage, files, network or processes", async () => {
  const h = harness();
  await h.event("session.start");
  await h.event("session.measure", usage());
  assert.deepEqual(h.calls, [["command", "quotatempo-probe"]]);
  assert.equal(h.writes.length, 0);
  assert.equal(h.nexts(), 2);
});

test("an explicit command connects but never polls or exports an initial cached value", async () => {
  const h = harness();
  assert.match((await h.command(`connect ${DIRECTORY}`)).text, /Comparison-only/);
  assert.equal(h.writes.length, 0);
  assert.equal(h.calls.filter(([kind]) => kind === "read").length, 1);
  await h.event("session.measure", { ...usage(), account: "synthetic", context: "synthetic" });
  assert.equal(h.writes.length, 1);
  const output = JSON.parse(h.writes[0][1]);
  assert.equal(output.result.rateLimits[0].percentUsed, 42);
  assert.equal(h.writes[0][1].includes("synthetic"), false);
  assert.equal(h.nexts(), 1);
});

test("unsafe paths, missing or expired grants fail without creating files", async () => {
  for (const path of ["relative", "/private/../probe", "/private//probe", "/private/probe/", "/private\\probe"]) {
    const h = harness();
    assert.match((await h.command(`connect ${path}`)).text, /failed/);
    assert.equal(h.calls.length, 0);
  }
  for (const setup of [h => h.unsafe(), h => h.time(NOW + 900_001), h => h.files.clear()]) {
    const h = harness(); setup(h);
    assert.match((await h.command(`connect ${DIRECTORY}`)).text, /failed/);
    assert.equal(h.writes.length, 0);
  }
});

test("disconnect, session end and reload invalidate without reconnecting", async () => {
  for (const end of [h => h.command("disconnect"), h => h.event("session.end"), h => h.event("session.start")]) {
    const h = harness();
    await h.command(`connect ${DIRECTORY}`);
    await h.event("session.measure", usage());
    await end(h);
    assert.equal(JSON.parse(h.writes.at(-1)[1]).result.reason, "disconnected");
    const count = h.writes.length;
    await h.event("session.measure", usage(50));
    assert.equal(h.writes.length, count);
    assert.match((await h.command("status")).text, /disconnected/);
  }
});

test("disconnect waits for pending export and invalidation is always last", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  let release;
  h.gate(new Promise(resolve => { release = resolve; }));
  const pending = h.event("session.measure", usage());
  while (h.writes.length === 0) await new Promise(resolve => setImmediate(resolve));
  const later = h.event("session.measure", usage(45));
  const closing = h.command("disconnect");
  release();
  h.gate(null);
  await Promise.all([pending, later, closing]);
  assert.equal(h.writes.length, 2);
  assert.equal(JSON.parse(h.writes.at(-1)[1]).result.reason, "disconnected");
});

test("disconnect and session end fence a connection still reading its grant", async () => {
  for (const end of [h => h.command("disconnect"), h => h.event("session.end"), h => h.event("session.start")]) {
    const h = harness();
    let release;
    let entered;
    const gate = new Promise(resolve => { release = resolve; });
    const reading = new Promise(resolve => { entered = resolve; });
    const read = h.$.fs.read;
    h.$.fs.read = async path => { entered(); await gate; return read(path); };
    const connecting = h.command(`connect ${DIRECTORY}`);
    await reading;
    await end(h);
    release();
    assert.match((await connecting).text, /cancelled/);
    assert.match((await h.command("status")).text, /disconnected/);
    await h.event("session.measure", usage());
    assert.equal(h.writes.length, 0);
  }
});

test("an older slow connect cannot replace a later connection", async () => {
  const h = harness();
  let release;
  let entered;
  let reads = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const reading = new Promise(resolve => { entered = resolve; });
  const read = h.$.fs.read;
  h.$.fs.read = async path => { if (++reads === 1) { entered(); await gate; } return read(path); };
  const first = h.command(`connect ${DIRECTORY}`);
  await reading;
  const second = await h.command(`connect ${DIRECTORY}`);
  assert.match(second.text, /connected/);
  release();
  assert.match((await first).text, /cancelled/);
  assert.match((await h.command("status")).text, new RegExp(second.text.match(/Stream: ([0-9a-f-]+)$/)[1]));
});

test("a busy export drains the latest invalid measurement instead of retaining an old value", async () => {
  for (const latest of [{ rateLimits: [] }, usage(50, "invalid")]) {
    const h = harness();
    await h.command(`connect ${DIRECTORY}`);
    let release;
    h.gate(new Promise(resolve => { release = resolve; }));
    const first = h.event("session.measure", usage());
    while (h.writes.length === 0) await new Promise(resolve => setImmediate(resolve));
    const invalidating = h.event("session.measure", latest);
    await new Promise(resolve => setImmediate(resolve));
    release();
    h.gate(null);
    await Promise.all([first, invalidating]);
    assert.equal(h.writes.length, 2);
    assert.equal(JSON.parse(h.writes.at(-1)[1]).result.status, "invalid");
    assert.deepEqual(JSON.parse(h.writes.at(-1)[1]).result.rateLimits, []);
  }
});

test("the pending slot is bounded and exports the most recent measurement", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  let release;
  h.gate(new Promise(resolve => { release = resolve; }));
  const first = h.event("session.measure", usage());
  while (h.writes.length === 0) await new Promise(resolve => setImmediate(resolve));
  const second = h.event("session.measure", usage(45));
  const third = h.event("session.measure", usage(55));
  await new Promise(resolve => setImmediate(resolve));
  release();
  h.gate(null);
  await Promise.all([first, second, third]);
  assert.equal(h.writes.length, 2);
  assert.equal(JSON.parse(h.writes.at(-1)[1]).result.rateLimits[0].percentUsed, 55);
});

test("a delayed older clock call cannot overwrite a newer measured event", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  let release;
  let entered;
  let calls = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const waiting = new Promise(resolve => { entered = resolve; });
  h.$.clock.now = async () => {
    if (++calls === 1) { entered(); await gate; }
    return NOW;
  };
  const older = h.event("session.measure", usage(45));
  await waiting;
  await h.event("session.measure", usage(55));
  release();
  await older;
  assert.equal(h.writes.length, 1);
  assert.equal(JSON.parse(h.writes[0][1]).result.rateLimits[0].percentUsed, 55);
});

test("sink errors stop export, keep hooks pass-through and reveal no raw exception", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  h.fail();
  await h.event("session.measure", usage());
  await h.event("session.measure", usage());
  assert.equal(h.writes.length, 2);
  assert.deepEqual(JSON.parse(h.writes[1][1]).result.rateLimits, []);
  assert.equal(h.nexts(), 2);
  assert.equal((await h.command("status")).text.includes("synthetic-private-error"), false);
  assert.match((await h.command("status")).text, /disconnected/);
});

test("reconnect and independent sessions write separate streams", async () => {
  const h = harness();
  await h.command(`connect ${DIRECTORY}`);
  await h.event("session.measure", usage());
  const firstPath = h.writes[0][0];
  await h.command(`connect ${DIRECTORY}`);
  await h.event("session.measure", usage(45));
  assert.notEqual(h.writes.at(-1)[0], firstPath);
  const other = harness();
  await other.command(`connect ${DIRECTORY}`);
  await other.event("session.measure", usage(90));
  assert.notEqual(other.writes[0][0], firstPath);
});

test("real private fixture directory receives and expires a synthetic hook export", async () => {
  const parent = await mkdtemp(join(await realpath(tmpdir()), "quotatempo-mods-test-"));
  try {
    const directory = join(parent, "probe");
    const prepared = await prepareDirectory(directory, NOW);
    assert.equal(prepared.status, "prepared");
    await assert.rejects(prepareDirectory(directory, NOW));
    const m = await message();
    m.connectionID = prepared.connectionID;
    await writeFile(join(directory, `stream-${STREAM}.json`), JSON.stringify(m), { mode: 0o644 });
    assert.equal((await inspectStream(directory, STREAM, NOW)).weekly.remainingPercent, 58);
    assert.equal((await inspectStream(directory, STREAM, NOW + 301_000)).status, "stale");
    await chmod(directory, 0o755);
    await assert.rejects(inspectStream(directory, STREAM, NOW));
    await chmod(directory, 0o700);
    await writeFile(join(directory, `stream-${STREAM}.json`), "{");
    assert.equal((await inspectStream(directory, STREAM, NOW)).status, "invalid_message");
    await rm(join(directory, `stream-${STREAM}.json`));
    await symlink(join(directory, "probe-grant.json"), join(directory, `stream-${STREAM}.json`));
    await assert.rejects(inspectStream(directory, STREAM, NOW));
    await assert.rejects(inspectStream(directory, "../../outside", NOW));
    const publicDir = join(parent, "public");
    await mkdir(publicDir, { mode: 0o755 });
    await assert.rejects(inspectStream(publicDir, STREAM, NOW));
    assert.equal(JSON.parse(await readFile(join(directory, "probe-grant.json"), "utf8")).purpose,
      "quotatempo-mods-comparison");
  } finally { await rm(parent, { recursive: true, force: true }); }
});

test("registered hook and real-file receiver complete a synthetic end-to-end round trip", async () => {
  const parent = await mkdtemp(join(await realpath(tmpdir()), "quotatempo-mods-roundtrip-"));
  try {
    const directory = join(parent, "probe");
    await prepareDirectory(directory, NOW);
    const h = harness();
    h.$.fs.stat = async path => {
      const stat = await lstat(path);
      return { kind: stat.isDirectory() ? "dir" : "file", isLink: stat.isSymbolicLink(),
        realPath: await realpath(path), size: stat.size };
    };
    h.$.fs.exists = async path => {
      try { await lstat(path); return true; } catch (error) {
        if (error.code === "ENOENT") return false;
        throw error;
      }
    };
    h.$.fs.read = path => readFile(path, "utf8");
    h.$.fs.write = async (path, text) => {
      assert(path.startsWith(`${directory}/stream-`));
      await writeFile(path, text, { mode: 0o644 });
    };
    const connected = await h.command(`connect ${directory}`);
    const id = connected.text.match(/Stream: ([0-9a-f-]+)$/)?.[1];
    assert(id);
    await h.event("session.measure", usage());
    const received = await inspectStream(directory, id, NOW);
    assert.equal(received.weekly.remainingPercent, 58);
    assert.equal(received.planningEligible, false);
    await h.command("disconnect");
    assert.equal((await inspectStream(directory, id, NOW)).status, "disconnected");
  } finally { await rm(parent, { recursive: true, force: true }); }
});

test("unsupported module loader has no declarative command, skill, agent or shell fallback (static only)", async () => {
  // This inspects configuration, not an unsupported live engine's behavior.
  const hooks = JSON.parse(await readFile(new URL("./hooks/hooks.json", import.meta.url), "utf8"));
  const plugin = JSON.parse(await readFile(new URL("./.claude-plugin/plugin.json", import.meta.url), "utf8"));
  assert.deepEqual(Object.keys(hooks), ["modules"]);
  assert.deepEqual(hooks.modules, ["./register.mjs"]);
  for (const fallback of ["commands", "skills", "agents", "mcpServers"]) {
    assert.equal(Object.hasOwn(plugin, fallback), false);
  }
  const adapter = await readFile(new URL("./hooks/register.mjs", import.meta.url), "utf8");
  assert.equal(/\bon\(["'](?:model\.|prompt\.|tool\.call)|\b(?:eval|require)\(|\bimport\(/.test(adapter), false);
});

test("prototype is outside the app graph and adapter has no sensitive acquisition calls", async () => {
  const root = new URL("../../", import.meta.url);
  const manifest = await readFile(new URL("Package.swift", root), "utf8");
  assert.equal(manifest.includes("claude-mods-usage"), false);
  const adapter = await readFile(new URL("./hooks/register.mjs", import.meta.url), "utf8");
  assert.equal(/\$\.session\.(?:usage|messages|id|authorize)|\$\.(?:process|env|model)|cachedUsageUtilization/.test(adapter), false);
  assert.equal((adapter.match(/\$\.http\.fetch\(/g) ?? []).length, 1);
  assert(adapter.includes('const control = current.control ?? current'));
  assert(adapter.includes('socketPath: control.socketPath'));
  assert.equal(adapter.includes('method: "POST", socketPath: current.socketPath'), false);
  const plugin = JSON.parse(await readFile(new URL("./.claude-plugin/plugin.json", import.meta.url), "utf8"));
  const hooks = JSON.parse(await readFile(new URL("./hooks/hooks.json", import.meta.url), "utf8"));
  const marketplace = JSON.parse(await readFile(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf8"));
  assert.equal(plugin.name, "quotatempo-usage-probe");
  assert.equal(plugin.version, "0.0.4");
  assert.equal(marketplace.metadata.version, plugin.version);
  assert.deepEqual(hooks, { modules: ["./register.mjs"] });
  assert.equal(marketplace.name, "quotatempo-local-probe");
  assert.equal(marketplace.plugins.length, 1);
  assert.equal(marketplace.plugins[0].name, plugin.name);
  assert.equal(marketplace.plugins[0].source, "./");
  assert.deepEqual(Object.keys(marketplace.plugins[0]).sort(), ["description", "name", "source"]);
});
