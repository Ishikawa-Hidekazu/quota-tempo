import assert from "node:assert/strict";
import test from "node:test";
import { createUsageProducer, normalizeUsage } from "./producer.mjs";

const T0 = "2026-10-03T00:00:00.000Z";
const T1 = "2026-10-03T00:01:00.000Z";
const T2 = "2026-10-03T00:02:00.000Z";
const SHORT_RESET = "2026-10-03T05:00:00.000Z";
const WEEK_RESET = "2026-10-10T00:00:00.000Z";

function weekly(percentUsed = 42, resetsAt = WEEK_RESET) {
  return { rateLimits: [{ kind: "seven_day", percentUsed, resetsAt }] };
}

function fakeProducer(values, times, sink = () => {}) {
  const deliveries = [];
  const calls = { getter: 0, clock: 0, sink: 0 };
  const producer = createUsageProducer({
    getUsage: async () => values[calls.getter++],
    clock: () => times[calls.clock++],
    sink: async (result) => {
      calls.sink += 1;
      deliveries.push(result);
      await sink(result);
    },
  });
  return { producer, deliveries, calls };
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test("normalizes the documented shape into only fixed quota and timestamp fields", () => {
  const input = {
    rateLimits: [
      { kind: "seven_day", percentUsed: 100, resetsAt: "2026-10-10T09:00:00+09:00", model: "synthetic-model" },
      { kind: "five_hour", percentUsed: 0, resetsAt: SHORT_RESET, text: "synthetic-text" },
    ],
    session: "synthetic-session",
    account: "synthetic-account",
    path: "synthetic-path",
    capturedAt: "2026-10-03T00:00:00Z",
  };
  const result = normalizeUsage(input, T0);
  assert.deepEqual(result, {
    schemaVersion: 1,
    status: "valid",
    reason: null,
    readAt: T0,
    rateLimits: [
      { kind: "five_hour", percentUsed: 0, resetsAt: SHORT_RESET },
      { kind: "seven_day", percentUsed: 100, resetsAt: WEEK_RESET },
    ],
  });
  assert.equal(input.rateLimits[0].kind, "seven_day");
  assert.equal(input.rateLimits[0].resetsAt, "2026-10-10T09:00:00+09:00");
  assert(Object.isFrozen(result));
  assert(Object.isFrozen(result.rateLimits));
  assert(result.rateLimits.every(Object.isFrozen));
});

test("unknown fields are not evaluated, traversed, serialized, or copied", () => {
  const input = weekly();
  let unknownReads = 0;
  for (const value of [input, input.rateLimits[0]]) {
    Object.defineProperty(value, "account", {
      enumerable: true,
      get() { unknownReads += 1; throw new Error("synthetic-content"); },
    });
    value.toJSON = () => { throw new Error("synthetic-content"); };
    value.self = value;
    value[Symbol("synthetic")] = "synthetic-content";
  }
  assert.deepEqual(normalizeUsage(input, T0), normalizeUsage(weekly(), T0));
  assert.equal(unknownReads, 0);
});

test("required fields must be own data properties, not inherited values or accessors", () => {
  let reads = 0;
  const usage = {};
  Object.defineProperty(usage, "rateLimits", { get() { reads += 1; return weekly().rateLimits; } });
  assert.equal(normalizeUsage(usage, T0).reason, "invalid_rate_limits");
  for (const key of ["kind", "percentUsed", "resetsAt"]) {
    const input = weekly();
    Object.defineProperty(input.rateLimits[0], key, { get() { reads += 1; return "synthetic"; } });
    assert.equal(normalizeUsage(input, T0).status, "invalid");
  }
  assert.equal(normalizeUsage(Object.create(weekly()), T0).status, "invalid");
  const nullPrototype = Object.assign(Object.create(null), weekly());
  assert.equal(normalizeUsage(nullPrototype, T0).status, "valid");
  assert.equal(reads, 0);
});

test("an uninspectable synthetic input fails with a fixed code, not an input exception", () => {
  const { proxy, revoke } = Proxy.revocable({}, {});
  revoke();
  assert.deepEqual(normalizeUsage(proxy, T0), {
    schemaVersion: 1, status: "invalid", reason: "invalid_usage", readAt: T0, rateLimits: [],
  });
});

test("accepts only finite numeric percentages within the inclusive range", () => {
  for (const percent of [0, -0, 0.125, 42.5, 100]) {
    const result = normalizeUsage(weekly(percent), T0);
    assert.equal(result.status, "valid");
    assert.equal(result.rateLimits[0].percentUsed, percent === 0 ? 0 : percent);
  }
  for (const percent of [NaN, Infinity, -Infinity, -0.001, 100.001, "42", null, true, {}, [], 42n]) {
    const result = normalizeUsage(weekly(percent), T0);
    assert.equal(result.reason, "invalid_percent_used");
    assert.deepEqual(result.rateLimits, []);
  }
  const missing = weekly();
  delete missing.rateLimits[0].percentUsed;
  assert.equal(normalizeUsage(missing, T0).reason, "invalid_percent_used");
});

test("rejects malformed, empty, sparse, oversized and ambiguous rate limits", () => {
  for (const input of [null, undefined, "synthetic", 1, [], new Date(T0)]) {
    assert.equal(normalizeUsage(input, T0).reason, "invalid_usage");
  }
  for (const rateLimits of [undefined, null, {}, [], new Array(3), [weekly().rateLimits[0], {}, {}]]) {
    assert.equal(normalizeUsage({ rateLimits }, T0).reason, "invalid_rate_limits");
  }
  for (const rateLimits of [new Array(1), [null], ["synthetic"], [[]]]) {
    assert.equal(normalizeUsage({ rateLimits }, T0).reason, "invalid_limit");
  }
  for (const kind of ["seven_day_sonnet", "synthetic-account", "", 7, null, undefined]) {
    assert.equal(normalizeUsage({ rateLimits: [{ kind, percentUsed: 1, resetsAt: WEEK_RESET }] }, T0).reason, "unknown_kind");
  }
  for (const kind of ["five_hour", "seven_day"]) {
    const rateLimits = [
      { kind, percentUsed: 1, resetsAt: WEEK_RESET },
      { kind, percentUsed: 2, resetsAt: SHORT_RESET },
    ];
    const result = normalizeUsage({ rateLimits }, T0);
    assert.equal(result.reason, "duplicate_kind");
    assert.deepEqual(result.rateLimits, []);
  }
});

test("missing, empty, malformed, and expired weekly resets never yield a valid quota", () => {
  const missing = { rateLimits: [{ kind: "seven_day", percentUsed: 42 }] };
  assert.equal(normalizeUsage(missing, T0).reason, "missing_reset");
  const malformed = [
    null, "", " ", 0, {}, new Date(WEEK_RESET),
    "not-a-date", "2026-10-10", "2026-10-10T00:00:00", "2026-10-10 00:00:00Z",
    "2026-10-10T24:00:00Z", "2026-10-10T00:60:00Z", "2026-10-10T00:00:60Z",
    "2026-02-29T00:00:00Z", "2026-02-30T00:00:00Z", "2026-04-31T00:00:00Z",
    "2026-00-10T00:00:00Z", "2026-13-10T00:00:00Z", "2026-10-00T00:00:00Z",
    "2026-10-10T00:00:00+24:00", "2026-10-10T00:00:00+00:60", "2026-10-10T00:00:00-00:00",
    "2026-10-10T00:00:00.0001Z", " 2026-10-10T00:00:00Z", "2026-10-10T00:00:00Z\n",
    "9999-12-31T23:59:59-01:00",
  ];
  for (const reset of malformed) {
    const result = normalizeUsage(weekly(42, reset), T0);
    assert.equal(result.status, "invalid");
    assert.equal(result.reason, "invalid_reset");
    assert.deepEqual(result.rateLimits, []);
  }
  for (const reset of ["2026-10-02T23:59:59.999Z", T0, "2026-10-03T09:00:00+09:00"]) {
    const result = normalizeUsage(weekly(42, reset), T0);
    assert.equal(result.reason, "expired_reset");
    assert.deepEqual(result.rateLimits, []);
  }
  assert.equal(normalizeUsage(weekly(42, "2026-10-03T00:00:00.001Z"), T0).status, "valid");
});

test("validates actual calendar dates and normalizes offsets without guessing timezone", () => {
  assert.equal(normalizeUsage(weekly(10, "2028-02-29T00:00:00Z"), T0).status, "valid");
  assert.equal(normalizeUsage(weekly(10, "2100-02-29T00:00:00Z"), T0).reason, "invalid_reset");
  assert.equal(normalizeUsage(weekly(10, "2400-02-29T00:00:00Z"), T0).status, "valid");
  assert.equal(normalizeUsage(weekly(10, "2026-10-09T19:00:00-05:00"), T0).rateLimits[0].resetsAt, WEEK_RESET);
  assert.equal(normalizeUsage(weekly(10, "2026-10-10T00:00:00.1Z"), T0).rateLimits[0].resetsAt, "2026-10-10T00:00:00.100Z");
});

test("invalid local read times cannot validate otherwise valid resets", () => {
  for (const readAt of [undefined, null, new Date(T0), 0, "", "2026-02-30T00:00:00Z", "2026-10-03"]) {
    assert.deepEqual(normalizeUsage(weekly(), readAt), {
      schemaVersion: 1, status: "invalid", reason: "invalid_read_at", readAt: null, rateLimits: [],
    });
  }
});

test("a bad limit rejects the entire read, not a partial exact-looking snapshot", () => {
  for (const bad of [
    { kind: "seven_day", percentUsed: 20 },
    { kind: "five_hour", percentUsed: 20, resetsAt: T0 },
  ]) {
    const good = { kind: bad.kind === "seven_day" ? "five_hour" : "seven_day", percentUsed: 10, resetsAt: WEEK_RESET };
    assert.deepEqual(normalizeUsage({ rateLimits: [good, bad] }, T0).rateLimits, []);
  }
  const shortOnly = normalizeUsage({ rateLimits: [{ kind: "five_hour", percentUsed: 10, resetsAt: SHORT_RESET }] }, T0);
  assert.equal(shortOnly.status, "valid");
  assert.equal(shortOnly.rateLimits.some((limit) => limit.kind === "seven_day"), false);
});

test("identical polling retains firstSeenAt and advances only local read timestamps", async () => {
  const fake = fakeProducer([weekly(), weekly(), weekly()], [T0, T1, T2]);
  const first = await fake.producer.poll();
  const second = await fake.producer.poll();
  const third = await fake.producer.poll();
  for (const [result, time] of [[first, T0], [second, T1], [third, T2]]) {
    assert.deepEqual(result, {
      schemaVersion: 1, status: "valid", reason: null, readAt: time,
      rateLimits: [{ kind: "seven_day", percentUsed: 42, resetsAt: WEEK_RESET, firstSeenAt: T0, lastReadAt: time }],
    });
  }
  assert.deepEqual(fake.calls, { getter: 3, clock: 3, sink: 3 });
  assert.deepEqual(fake.deliveries, [first, second, third]);
});

test("order, unknown metadata and equivalent reset formatting do not create observations", async () => {
  const short = { kind: "five_hour", percentUsed: 5, resetsAt: SHORT_RESET };
  const fake = fakeProducer([
    { rateLimits: [short, ...weekly().rateLimits] },
    { account: "different-synthetic-value", rateLimits: [
      { kind: "seven_day", percentUsed: 42, resetsAt: "2026-10-10T09:00:00+09:00", model: "synthetic" }, short,
    ] },
  ], [T0, T1]);
  await fake.producer.poll();
  const result = await fake.producer.poll();
  assert(result.rateLimits.every((limit) => limit.firstSeenAt === T0 && limit.lastReadAt === T1));
});

test("changed reset invalidates old window continuity even with identical usage", async () => {
  const newReset = "2026-10-17T00:00:00.000Z";
  const fake = fakeProducer([weekly(), weekly(42, newReset), weekly(42, newReset)], [T0, T1, T2]);
  await fake.producer.poll();
  const changed = await fake.producer.poll();
  assert.deepEqual(changed.rateLimits[0], {
    kind: "seven_day", percentUsed: 42, resetsAt: newReset, firstSeenAt: T1, lastReadAt: T1,
  });
  assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T1);
});

test("percentage changes are local value changes, including a decrease", async () => {
  const fake = fakeProducer([weekly(40), weekly(42), weekly(40)], [T0, T1, T2]);
  await fake.producer.poll();
  assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T1);
  assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T2);
});

test("a change in one present window does not refresh the unchanged window", async () => {
  const short = { kind: "five_hour", percentUsed: 5, resetsAt: SHORT_RESET };
  const fake = fakeProducer([
    { rateLimits: [short, ...weekly().rateLimits] },
    { rateLimits: [{ ...short, percentUsed: 6 }, ...weekly().rateLimits] },
  ], [T0, T1]);
  await fake.producer.poll();
  const result = await fake.producer.poll();
  assert.equal(result.rateLimits[0].firstSeenAt, T1);
  assert.equal(result.rateLimits[1].firstSeenAt, T0);
  assert(result.rateLimits.every((limit) => limit.lastReadAt === T1));
});

test("invalid or missing weekly reset cannot borrow a previous exact-looking reset", async () => {
  for (const bad of [
    { rateLimits: [] },
    { rateLimits: [{ kind: "seven_day", percentUsed: 42 }] },
    weekly(42, ""), weekly(42, "malformed"), weekly(42, T1),
  ]) {
    const fake = fakeProducer([weekly(), bad, weekly()], [T0, T1, T2]);
    await fake.producer.poll();
    const invalid = await fake.producer.poll();
    assert.equal(invalid.status, "invalid");
    assert.deepEqual(invalid.rateLimits, []);
    assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T2);
  }
});

test("identical values become invalid at reset expiry, not freshly observed", async () => {
  const fake = fakeProducer([weekly(42, T1), weekly(42, T1)], [T0, T1]);
  await fake.producer.poll();
  const expired = await fake.producer.poll();
  assert.equal(expired.reason, "expired_reset");
  assert.deepEqual(expired.rateLimits, []);
});

test("one window changing or disappearing cannot refresh or restore the other window", async () => {
  const short = { kind: "five_hour", percentUsed: 5, resetsAt: SHORT_RESET };
  const fake = fakeProducer([
    { rateLimits: [short, ...weekly().rateLimits] },
    { rateLimits: [{ ...short, percentUsed: 6 }] },
    { rateLimits: [{ ...short, percentUsed: 6 }, ...weekly().rateLimits] },
  ], [T0, T1, T2]);
  await fake.producer.poll();
  const second = await fake.producer.poll();
  assert.equal(second.rateLimits.length, 1);
  const third = await fake.producer.poll();
  assert.equal(third.rateLimits[0].firstSeenAt, T1);
  assert.equal(third.rateLimits[1].firstSeenAt, T2);
});

test("readAt is sampled after the fake getter completes", async () => {
  const pending = deferred();
  let now = T0;
  const deliveries = [];
  const producer = createUsageProducer({ getUsage: () => pending.promise, clock: () => now, sink: (value) => deliveries.push(value) });
  const poll = producer.poll();
  now = T1;
  pending.resolve(weekly());
  assert.equal((await poll).readAt, T1);
  assert.equal(deliveries.length, 1);
});

test("overlapping polls are rejected without a second getter or sink call", async () => {
  for (const blockedAt of ["getter", "sink"]) {
    const pending = deferred();
    const entered = deferred();
    let gets = 0;
    let sinks = 0;
    const producer = createUsageProducer({
      getUsage: async () => { gets += 1; if (blockedAt === "getter") { entered.resolve(); await pending.promise; } return weekly(); },
      clock: () => T0,
      sink: async () => { sinks += 1; if (blockedAt === "sink") { entered.resolve(); await pending.promise; } },
    });
    const first = producer.poll();
    await entered.promise;
    await assert.rejects(producer.poll(), { message: "poll_in_progress" });
    assert.equal(gets, 1);
    pending.resolve();
    await first;
    assert.equal(sinks, 1);
  }
});

test("getter and clock failures emit fixed statuses, clear continuity, and never leak errors", async () => {
  for (const failingAt of ["getter", "clock"]) {
    let round = 0;
    const deliveries = [];
    const producer = createUsageProducer({
      getUsage: () => { round += 1; if (round === 2 && failingAt === "getter") throw new Error("synthetic-private-text"); return weekly(); },
      clock: () => { if (round === 2 && failingAt === "clock") throw new Error("synthetic-private-text"); return round === 1 ? T0 : T2; },
      sink: (value) => deliveries.push(value),
    });
    await producer.poll();
    assert.deepEqual(await producer.poll(), {
      schemaVersion: 1, status: "unavailable", reason: `${failingAt}_failed`, readAt: null, rateLimits: [],
    });
    assert.equal((await producer.poll()).rateLimits[0].firstSeenAt, T2);
    assert.equal(JSON.stringify(deliveries).includes("synthetic-private-text"), false);
  }
});

test("rejected async getters are contained without retries", async () => {
  let calls = 0;
  const deliveries = [];
  const producer = createUsageProducer({
    getUsage: async () => { calls += 1; throw new Error("synthetic-private-text"); },
    clock: () => { throw new Error("clock must not run"); },
    sink: (value) => deliveries.push(value),
  });
  assert.equal((await producer.poll()).reason, "getter_failed");
  assert.equal(calls, 1);
  assert.equal(deliveries.length, 1);
});

test("clock regression fails closed without moving the watermark backwards", async () => {
  const fake = fakeProducer([weekly(), weekly(), weekly(), weekly()], [T1, T0, T0, T2]);
  await fake.producer.poll();
  for (let index = 0; index < 2; index += 1) {
    const result = await fake.producer.poll();
    assert.equal(result.reason, "clock_regressed");
    assert.deepEqual(result.rateLimits, []);
  }
  assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T2);
});

test("invalid clocks clear continuity and equal clock readings do not create observations", async () => {
  const fake = fakeProducer([weekly(), weekly(), weekly(), weekly()], [T0, "synthetic-invalid-time", T2, T2]);
  await fake.producer.poll();
  const invalid = await fake.producer.poll();
  assert.equal(invalid.reason, "invalid_read_at");
  assert.equal(invalid.readAt, null);
  assert.deepEqual(invalid.rateLimits, []);
  const recovered = await fake.producer.poll();
  assert.equal(recovered.rateLimits[0].firstSeenAt, T2);
  assert.deepEqual(await fake.producer.poll(), recovered);
});

test("sink failure has uncertain delivery, no replay, and does not rewrite firstSeenAt", async () => {
  let now = T0;
  let sinks = 0;
  const delivered = [];
  const producer = createUsageProducer({
    getUsage: () => weekly(),
    clock: () => now,
    sink: async (value) => {
      sinks += 1;
      delivered.push(value);
      if (sinks === 1) throw new Error("synthetic-private-text");
    },
  });
  await assert.rejects(producer.poll(), (error) => {
    assert.equal(error.message, "sink_failed");
    assert.equal(Object.hasOwn(error, "cause"), false);
    return true;
  });
  assert.equal(sinks, 1);
  now = T1;
  const next = await producer.poll();
  assert.equal(next.rateLimits[0].firstSeenAt, T0);
  assert.equal(next.rateLimits[0].lastReadAt, T1);
  assert.equal(delivered.length, 2);
});

test("returned snapshots and sink inputs cannot mutate subsequent continuity", async () => {
  const fake = fakeProducer([weekly(), weekly()], [T0, T1], (result) => {
    assert.throws(() => { result.rateLimits[0].firstSeenAt = T2; }, TypeError);
    assert.throws(() => { result.rateLimits.push({}); }, TypeError);
    assert.throws(() => { result.readAt = T2; }, TypeError);
  });
  const result = await fake.producer.poll();
  assert.throws(() => { result.rateLimits[0].resetsAt = T2; }, TypeError);
  assert.equal((await fake.producer.poll()).rateLimits[0].firstSeenAt, T0);
});

test("instances have isolated, in-memory-only continuity", async () => {
  const first = fakeProducer([weekly()], [T0]);
  const second = fakeProducer([weekly()], [T1]);
  assert.equal((await first.producer.poll()).rateLimits[0].firstSeenAt, T0);
  assert.equal((await second.producer.poll()).rateLimits[0].firstSeenAt, T1);
});

test("construction validates injection without starting work", () => {
  let calls = 0;
  const callback = () => { calls += 1; };
  const dependencies = { getUsage: callback, clock: callback, sink: callback };
  createUsageProducer(dependencies);
  for (const key of Object.keys(dependencies)) {
    assert.throws(() => createUsageProducer({ ...dependencies, [key]: null }), TypeError);
  }
  assert.equal(calls, 0);
});
