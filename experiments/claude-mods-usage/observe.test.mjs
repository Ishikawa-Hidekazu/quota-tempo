import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createStreamObserver, observeStream } from "./observe.mjs";
import { prepareDirectory, readStreamRecord } from "./receiver.mjs";
import { createUsageProducer } from "./producer.mjs";
import { encodeMessage } from "./protocol.mjs";

const NOW = Date.parse("2026-10-06T00:00:00.000Z");
const STREAM = "22222222-2222-4222-8222-222222222222";
const CONNECTION = "11111111-1111-4111-8111-111111111111";
const OTHER = "33333333-3333-4333-8333-333333333333";

async function record(sequence = 1, at = NOW, used = 42, reset = NOW + 7 * 86400_000) {
  const producer = createUsageProducer({ getUsage: () => ({ rateLimits: [{ kind: "seven_day",
    percentUsed: used, resetsAt: new Date(reset).toISOString() }] }),
  clock: () => new Date(at).toISOString(), sink: () => {} });
  return { connectionID: CONNECTION, streamID: STREAM,
    message: encodeMessage({ connectionID: CONNECTION, streamID: STREAM, sequence, result: await producer.poll() }) };
}

test("unchanged file reads keep the observation without refreshing its age", async () => {
  const value = await record();
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => value });
  assert.equal((await observer.sample(NOW)).weekly.remainingPercent, 58);
  assert.equal((await observer.sample(NOW + 1000)).weekly.firstSeenAt, new Date(NOW).toISOString());
  assert.equal((await observer.sample(NOW + 300_000)).status, "comparison_only");
  const expired = await observer.sample(NOW + 300_001);
  assert.equal(expired.status, "stale");
  assert.equal(expired.weekly, null);
});

test("a delayed read is validated at completion, not before I/O", async () => {
  for (const [reset, finish, expected] of [
    [NOW + 7 * 86400_000, NOW + 300_001, "stale"],
    [NOW + 60_000, NOW + 60_000, "reset_passed"],
    [NOW + 7 * 86400_000, NOW - 1, "invalid_clock"],
  ]) {
    let now = NOW;
    const value = await record(1, NOW, 42, reset);
    const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => {
      now = finish;
      return value;
    } });
    const received = await observer.sample(() => now);
    assert.equal(received.status, expected);
    assert.equal(received.weekly, null);
  }
});

test("a delayed identical reread cannot retain a value beyond its reset", async () => {
  let now = NOW;
  let delayed = false;
  const value = await record(1, NOW, 42, NOW + 60_000);
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => {
    if (delayed) now += 60_000;
    return value;
  } });
  assert.equal((await observer.sample(() => now)).status, "comparison_only");
  delayed = true;
  assert.equal((await observer.sample(() => now)).status, "reset_passed");
});

test("fresh sequence advances; replay, partial data and missing files clear the view", async () => {
  let value = await record();
  let error = false;
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => {
    if (error) throw new Error("synthetic-private-error");
    return value;
  } });
  assert.equal((await observer.sample(NOW)).status, "comparison_only");
  const first = value;
  value = await record(2, NOW + 1000, 43);
  assert.equal((await observer.sample(NOW + 1000)).weekly.remainingPercent, 57);
  value = first;
  assert.equal((await observer.sample(NOW + 2000)).weekly, null);
  value = { ...value, message: "{" };
  assert.equal((await observer.sample(NOW + 3000)).status, "invalid_message");
  error = true;
  assert.equal((await observer.sample(NOW + 4000)).status, "stream_unavailable");
  error = false;
  value = await record(3, NOW + 5000, 44);
  assert.equal((await observer.sample(NOW + 5000)).weekly.remainingPercent, 56);
});

test("recovery of the same old file never restores a lost observation", async () => {
  const value = await record();
  let error = false;
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => {
    if (error) throw new Error();
    return value;
  } });
  await observer.sample(NOW);
  error = true;
  await observer.sample(NOW + 1000);
  error = false;
  assert.equal((await observer.sample(NOW + 2000)).weekly, null);
});

test("grant changes and another stream are never selected automatically", async () => {
  let value = await record();
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => value });
  await observer.sample(NOW);
  value = { ...value, streamID: OTHER };
  assert.equal((await observer.sample(NOW)).status, "invalid_binding");
  value = { ...value, streamID: STREAM, connectionID: OTHER };
  assert.equal((await observer.sample(NOW)).status, "connection_changed");
});

test("clock rollback and passed resets clear even an unchanged file", async () => {
  const value = await record(1, NOW, 42, NOW + 60_000);
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => value });
  await observer.sample(NOW);
  assert.equal((await observer.sample(NOW - 1)).status, "invalid_clock");
  assert.equal((await observer.sample(NOW)).weekly, null);
  const other = createStreamObserver({ streamID: STREAM, readRecord: async () => value });
  await other.sample(NOW);
  assert.equal((await other.sample(NOW + 60_000)).status, "reset_passed");
});

test("disconnect invalidates and concurrency does not duplicate a read", async () => {
  let release;
  let value = await record();
  const gate = new Promise(resolve => { release = resolve; });
  const observer = createStreamObserver({ streamID: STREAM, readRecord: async () => {
    await gate;
    return value;
  } });
  const pending = observer.sample(NOW);
  await assert.rejects(observer.sample(NOW), { message: "observation_in_progress" });
  release();
  await pending;
  value = { ...value, message: encodeMessage({ connectionID: CONNECTION, streamID: STREAM, sequence: 2,
    result: { schemaVersion: 1, status: "unavailable", reason: "disconnected",
      readAt: new Date(NOW).toISOString(), rateLimits: [] } }) };
  assert.equal((await observer.sample(NOW)).status, "disconnected");
  assert.equal((await observer.sample(NOW + 1000)).weekly, null);
});

test("real private files bind one stream and observation stops without modifying them", async () => {
  const parent = await mkdtemp(join(await realpath(tmpdir()), "quotatempo-observe-"));
  try {
    const directory = join(parent, "probe");
    const prepared = await prepareDirectory(directory, NOW);
    const value = await record();
    const message = JSON.parse(value.message);
    message.connectionID = prepared.connectionID;
    await writeFile(join(directory, `stream-${STREAM}.json`), JSON.stringify(message), { mode: 0o600 });
    const observer = createStreamObserver({ streamID: STREAM, readRecord: () => readStreamRecord(directory, STREAM) });
    assert.equal((await observer.sample(NOW)).weekly.remainingPercent, 58);
    const controller = new AbortController();
    const views = [];
    const status = await observeStream(directory, STREAM, 10, { signal: controller.signal,
      emit: view => { views.push(view); controller.abort(); } });
    assert.equal(status, "observation_stopped");
    assert.equal(views.length, 1);
    assert.equal(views[0].planningEligible, false);
    assert.equal((await readStreamRecord(directory, STREAM)).message, JSON.stringify(message));
  } finally { await rm(parent, { recursive: true, force: true }); }
});

test("bounded runner rejects unsafe duration and supports an already-aborted signal", async () => {
  for (const seconds of [0, -1, 1801, Infinity, 1.5, "10"]) {
    await assert.rejects(observeStream("/unused", STREAM, seconds, { emit: () => {} }));
  }
  const controller = new AbortController();
  controller.abort();
  assert.equal(await observeStream("/unused", STREAM, 1, { signal: controller.signal,
    emit: () => assert.fail("must not emit") }), "observation_stopped");
});
