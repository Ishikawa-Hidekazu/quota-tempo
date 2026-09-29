const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const protocol = require("../protocol.js");

const NOW = Date.parse("2026-09-29T00:00:00.000Z");
const ACCOUNT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ACCOUNT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const ORG = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const WEEKLY = "2026-10-03T00:00:00.000Z";
const FIVE_HOUR = "2026-09-29T03:00:00.000Z";

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status });
}

function fetchSequence(...replies) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return replies.shift();
  };
  return { calls, fetchImpl };
}

function oldUsage(extra = {}) {
  return {
    seven_day: { utilization: 27, resets_at: WEEKLY },
    five_hour: { utilization: 10, resets_at: FIVE_HOUR },
    ...extra
  };
}

test("old usage is normalized and account/organization UUIDs are hashed", async () => {
  const source = fetchSequence(
    response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }]),
    response(oldUsage()), response({ uuid: ACCOUNT_A })
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  const sha = value => createHash("sha256").update(value).digest("hex");
  assert.equal(result.status, "ok");
  assert.equal(result.accountFingerprint, sha(`claude-owner-v1:${ACCOUNT_A}:${ORG}`));
  assert.equal(result.organizationFingerprint, sha(ORG));
  assert.equal(result.principalFingerprint, sha(ACCOUNT_A));
  assert.deepEqual(result.weekly, { remainingPercent: 73, resetAt: WEEKLY });
  assert.deepEqual(result.fiveHour, { remainingPercent: 90, resetAt: FIVE_HOUR });
  assert.deepEqual(source.calls.map(call => new URL(call.url).pathname), [
    "/api/account", "/api/organizations", `/api/organizations/${ORG}/usage`, "/api/account"
  ]);
  for (const call of source.calls) {
    assert.equal(call.options.credentials, "include");
    assert.equal(call.options.cache, "no-store");
    assert.equal(call.options.redirect, "error");
    assert.equal(new URL(call.url).origin, "https://claude.ai");
  }
});

test("new limits accept only all-model weekly and session; unknown fields are ignored", () => {
  const parsed = protocol.parseUsage({
    future_field: { private: "ignored" },
    limits: [
      { kind: "weekly_scoped", utilization: 99, resets_at: WEEKLY },
      { kind: "weekly_all", used_percentage: 35, resets_at: WEEKLY, future: true },
      { kind: "session", utilization: 12.5, resets_at: FIVE_HOUR },
      { kind: "unrecognized", utilization: 1, resets_at: WEEKLY }
    ]
  }, NOW);
  assert.deepEqual(parsed.weekly, { remainingPercent: 65, resetAt: WEEKLY });
  assert.deepEqual(parsed.fiveHour, { remainingPercent: 87.5, resetAt: FIVE_HOUR });
});

test("explicit null five-hour bucket does not invalidate a weekly observation", () => {
  const parsed = protocol.parseUsage(oldUsage({ five_hour: null }), NOW);
  assert.deepEqual(parsed.weekly, { remainingPercent: 73, resetAt: WEEKLY });
  assert.equal(parsed.fiveHour, null);
});

test("same-organization account switch during observation is rejected", async () => {
  const source = fetchSequence(
    response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }]),
    response(oldUsage()), response({ uuid: ACCOUNT_B })
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  assert.equal(result.status, "accountChanged");
  assert.equal(result.accountFingerprint, null);
  assert.equal(result.weekly, null);
});

test("401 and 429 return status-only observations", async () => {
  for (const [status, expected] of [[401, "signedOut"], [429, "rateLimited"]]) {
    const source = fetchSequence(response({}, status));
    const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
    assert.equal(result.status, expected);
    assert.equal(result.principalFingerprint, null);
    assert.equal(result.weekly, null);
  }
});

test("total timeout aborts and produces no usage", async () => {
  const fetchImpl = (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
  });
  const result = await protocol.observe({ fetchImpl, now: () => NOW, timeoutMs: 10 });
  assert.equal(result.status, "unavailable");
  assert.equal(result.weekly, null);
});

test("multiple organizations are not selected arbitrarily", async () => {
  const source = fetchSequence(
    response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }, { uuid: ACCOUNT_B }])
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  assert.equal(result.status, "organizationSelectionRequired");
  assert.equal(source.calls.length, 2);
});

test("oversized response is rejected before parsing or forwarding", async () => {
  const fetchImpl = async () => new Response("x".repeat(128 * 1024 + 1));
  const result = await protocol.observe({ fetchImpl, now: () => NOW });
  assert.equal(result.status, "unavailable");
  assert.equal(result.accountFingerprint, null);
});

test("ambiguous duplicate buckets fail closed", () => {
  assert.throws(() => protocol.parseUsage({
    ...oldUsage(), limits: [{ kind: "weekly_all", utilization: 27, resets_at: WEEKLY }]
  }, NOW));
  assert.throws(() => protocol.parseUsage({
    limits: [
      { kind: "weekly_all", utilization: 27, resets_at: WEEKLY },
      { kind: "weekly_all", utilization: 27, resets_at: WEEKLY }
    ]
  }, NOW));
});

test("invalid, elapsed, too-distant, and nonfinite windows fail closed", () => {
  for (const reset of [
    "2026-02-30T01:00:00Z", "2026-09-28T23:00:00Z", "2026-10-08T00:00:00Z",
    "2026-10-03T00:00:00+00:00"
  ]) {
    assert.throws(() => protocol.parseUsage({ seven_day: { utilization: 2, resets_at: reset } }, NOW));
  }
  assert.throws(() => protocol.parseUsage({ seven_day: { utilization: NaN, resets_at: WEEKLY } }, NOW));
  assert.throws(() => protocol.parseUsage({
    seven_day: { utilization: 2, resets_at: WEEKLY },
    five_hour: { utilization: 2, resets_at: "2026-09-29T07:00:00Z" }
  }, NOW));
});
