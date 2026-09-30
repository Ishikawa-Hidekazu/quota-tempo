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

test("email-only account responses are compared and hashed without forwarding the address", async () => {
  const email = "Example.User@example.com";
  const source = fetchSequence(
    response({ email_address: email }), response([{ uuid: ORG }]),
    response(oldUsage()), response({ email_address: email })
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  const sha = value => createHash("sha256").update(value).digest("hex");
  const principal = "email:example.user@example.com";
  assert.equal(result.status, "ok");
  assert.equal(result.accountFingerprint, sha(`claude-owner-v1:${principal}:${ORG}`));
  assert.equal(result.principalFingerprint, sha(principal));
  assert.equal(JSON.stringify(result).includes(email), false);
  assert.equal(JSON.stringify(result).includes("example.user@example.com"), false);
});

test("email-only account switch during acquisition fails closed", async () => {
  const source = fetchSequence(
    response({ email_address: "a@example.com" }), response([{ uuid: ORG }]),
    response(oldUsage()), response({ email_address: "b@example.com" })
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  assert.equal(result.status, "accountChanged");
  assert.equal(result.weekly, null);
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

test("elapsed optional five-hour windows do not discard a current exact weekly observation", () => {
  for (const reset of ["2026-09-28T23:59:59Z", "2026-09-29T09:00:00+09:00"]) {
    const session = { utilization: 80, resets_at: reset };
    for (const usage of [
      oldUsage({ five_hour: session }),
      { limits: [{ kind: "weekly_all", utilization: 27, resets_at: WEEKLY }, { kind: "session", ...session }] },
      oldUsage({ five_hour: session, limits: [{ kind: "session", ...session }] })
    ]) {
      assert.deepEqual(protocol.parseUsage(usage, NOW), {
        weekly: { remainingPercent: 73, resetAt: WEEKLY }, fiveHour: null
      });
    }
  }
});

test("optional window omission does not hide conflicting or malformed expired buckets", () => {
  const elapsed = { utilization: 80, resets_at: "2026-09-28T23:59:59Z" };
  for (const session of [
    { ...elapsed, utilization: 81 },
    { ...elapsed, resets_at: "2026-09-28T23:59:58Z" },
    { ...elapsed, resets_at: FIVE_HOUR }
  ]) {
    assert.throws(() => protocol.parseUsage(oldUsage({
      five_hour: elapsed, limits: [{ kind: "session", ...session }]
    }), NOW));
  }
  assert.throws(() => protocol.parseUsage(oldUsage({
    five_hour: elapsed, limits: [{ kind: "session", ...elapsed }, { kind: "session", ...elapsed }]
  }), NOW));
  for (const session of [
    { ...elapsed, utilization: NaN }, { ...elapsed, utilization: -1 },
    { ...elapsed, utilization: 101 }, { ...elapsed, utilization: "80" },
    { ...elapsed, percent: 80 }, { ...elapsed, resets_at: null },
    { ...elapsed, resets_at: "2026-02-30T00:00:00Z" },
    { ...elapsed, resets_at: "2026-09-28T23:59:59+24:00" }
  ]) {
    for (const usage of [oldUsage({ five_hour: session }),
      oldUsage({ five_hour: null, limits: [{ kind: "session", ...session }] })]) {
      assert.throws(() => protocol.parseUsage(usage, NOW));
    }
  }
});

test("five-hour rollover transitions to absent then a newly observed window, never an inferred one", async () => {
  const reset = "2026-09-29T00:00:00.000Z";
  const newReset = "2026-09-29T05:00:00.000Z";
  for (const [now, reportedReset, expected] of [
    [NOW - 1, reset, { remainingPercent: 20, resetAt: reset }],
    [NOW, reset, null],
    [NOW + 23_000, reset, null],
    [NOW + 5 * 60_000, newReset, { remainingPercent: 20, resetAt: newReset }]
  ]) {
    const source = fetchSequence(response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }]),
      response(oldUsage({ five_hour: { utilization: 80, resets_at: reportedReset } })),
      response({ uuid: ACCOUNT_A }));
    const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => now });
    assert.equal(result.status, "ok");
    assert.deepEqual(result.weekly, { remainingPercent: 73, resetAt: WEEKLY });
    assert.deepEqual(result.fiveHour, expected);
  }
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
  assert.equal(result.diagnostic, "accountRequest");
});

test("only bounded stage names leave a failed acquisition", async () => {
  const cases = [
    { replies: [response({ unexpected: true })], stage: "accountShape" },
    { replies: [response({ uuid: ACCOUNT_A }), response({ unexpected: true })], stage: "organizationsShape" },
    { replies: [response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }]), response({}),
      response({ uuid: ACCOUNT_A })], stage: "usageShape" }
  ];
  for (const item of cases) {
    const source = fetchSequence(...item.replies);
    const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
    assert.equal(result.status, "unavailable");
    assert.equal(result.diagnostic, item.stage);
    assert.equal(result.weekly, null);
    assert.equal(result.accountFingerprint, null);
  }
});

test("matching legacy and limits buckets merge after normalization", () => {
  assert.deepEqual(protocol.parseUsage({
    ...oldUsage(), limits: [{ kind: "weekly_all", utilization: 27, resets_at: WEEKLY }]
  }, NOW), protocol.parseUsage(oldUsage(), NOW));
  const usage = {
    seven_day: { utilization: 27, resets_at: "2026-10-03T00:00:00.123456+00:00" },
    five_hour: { utilization: 10, resets_at: "2026-09-29T03:00:00.987654+00:00" },
    limits: [
      { kind: "weekly_all", percent: 27, resets_at: "2026-10-03T09:00:00.123999999+09:00" },
      { kind: "session", percent: 10, resets_at: "2026-09-28T20:00:00.987654321-07:00" },
      { kind: "weekly_scoped", percent: 5, resets_at: WEEKLY }
    ]
  };
  assert.deepEqual(protocol.parseUsage(usage, NOW), {
    weekly: { remainingPercent: 73, resetAt: "2026-10-03T00:00:00.123Z" },
    fiveHour: { remainingPercent: 90, resetAt: "2026-09-29T03:00:00.987Z" }
  });
});

test("conflicting legacy and limits buckets or duplicate limits fail closed", () => {
  for (const [kind, percent, reset] of [["weekly_all", 27, WEEKLY], ["session", 10, FIVE_HOUR]]) {
    for (const mismatch of [
      { percent: percent + 1, resets_at: reset },
      { percent, resets_at: new Date(Date.parse(reset) + 1).toISOString() }
    ]) {
      assert.throws(() => protocol.parseUsage({ ...oldUsage(), limits: [{ kind, ...mismatch }] }, NOW));
    }
    const limit = { kind, percent, resets_at: reset };
    assert.throws(() => protocol.parseUsage({ ...oldUsage(), limits: [limit, { ...limit }] }, NOW));
  }
  assert.throws(() => protocol.parseUsage({
    limits: [
      { kind: "weekly_all", percent: 27, resets_at: WEEKLY },
      { kind: "weekly_all", percent: 27, resets_at: WEEKLY }
    ]
  }, NOW));
});

test("each window accepts exactly one utilization key", () => {
  const keys = ["utilization", "used_percentage", "percent"];
  for (const key of keys) {
    const row = { [key]: 27, resets_at: WEEKLY };
    assert.equal(protocol.parseUsage({ seven_day: row }, NOW).weekly.remainingPercent, 73);
    assert.equal(protocol.parseUsage({ limits: [{ kind: "weekly_all", ...row }] }, NOW).weekly.remainingPercent, 73);
    for (const other of keys.filter(candidate => candidate !== key)) {
      for (const value of [27, null, undefined]) {
        assert.throws(() => protocol.parseUsage({ seven_day: { ...row, [other]: value } }, NOW));
      }
    }
    for (const value of [null, undefined, "27", NaN, Infinity, -1, 101]) {
      assert.throws(() => protocol.parseUsage({ seven_day: { [key]: value, resets_at: WEEKLY } }, NOW));
    }
  }
  assert.throws(() => protocol.parseUsage({ seven_day: { resets_at: WEEKLY } }, NOW));
});

test("numeric offsets and zero to nine fractional digits normalize in both schemas and windows", () => {
  const formats = [
    ["2026-10-03T00:00:00", "2026-09-29T03:00:00", "Z"],
    ["2026-10-03T00:00:00", "2026-09-29T03:00:00", "+00:00"],
    ["2026-10-03T00:00:00", "2026-09-29T03:00:00", "-00:00"],
    ["2026-10-03T09:00:00", "2026-09-29T12:00:00", "+09:00"],
    ["2026-10-03T05:30:00", "2026-09-29T08:30:00", "+05:30"],
    ["2026-10-02T17:00:00", "2026-09-28T20:00:00", "-07:00"],
    ["2026-10-02T20:30:00", "2026-09-28T23:30:00", "-03:30"]
  ];
  for (let precision = 0; precision <= 9; precision++) {
    const digits = "123456789".slice(0, precision);
    const fraction = precision ? `.${digits}` : "";
    const milliseconds = digits.padEnd(3, "0").slice(0, 3);
    for (const [weeklyLocal, sessionLocal, zone] of formats) {
      const weekly = { percent: 27, resets_at: `${weeklyLocal}${fraction}${zone}` };
      const session = { used_percentage: 10, resets_at: `${sessionLocal}${fraction}${zone}` };
      for (const usage of [
        { seven_day: weekly, five_hour: session },
        { limits: [{ kind: "weekly_all", ...weekly }, { kind: "session", ...session }] }
      ]) {
        assert.deepEqual(protocol.parseUsage(usage, NOW), {
          weekly: { remainingPercent: 73, resetAt: `2026-10-03T00:00:00.${milliseconds}Z` },
          fiveHour: { remainingPercent: 90, resetAt: `2026-09-29T03:00:00.${milliseconds}Z` }
        });
      }
    }
  }
});

test("matching mixed-schema synthetic observations succeed without losing either window", async () => {
  const weekly = "2026-10-03T00:00:00.123456+00:00";
  const session = "2026-09-29T03:00:00.987654321+00:00";
  const source = fetchSequence(
    response({ uuid: ACCOUNT_A }), response([{ uuid: ORG }]),
    response({
      seven_day: { utilization: 27, resets_at: weekly },
      five_hour: { utilization: 10, resets_at: session },
      limits: [
        { kind: "weekly_all", percent: 27, resets_at: weekly },
        { kind: "session", percent: 10, resets_at: session }
      ]
    }), response({ uuid: ACCOUNT_A })
  );
  const result = await protocol.observe({ fetchImpl: source.fetchImpl, now: () => NOW });
  assert.equal(result.status, "ok");
  assert.deepEqual(result.weekly, { remainingPercent: 73, resetAt: "2026-10-03T00:00:00.123Z" });
  assert.deepEqual(result.fiveHour, { remainingPercent: 90, resetAt: "2026-09-29T03:00:00.987Z" });
});

test("calendar and clock overflow are rejected even inside the future window", () => {
  for (const [reset, now] of [
    ["2026-09-31T00:00:00Z", NOW],
    ["2026-09-31T09:00:00+09:00", NOW],
    ["2026-02-29T00:00:00.123456Z", Date.parse("2026-02-27T00:00:00Z")],
    ["2100-02-29T00:00:00+00:00", Date.parse("2100-02-27T00:00:00Z")],
    ["2026-13-01T00:00:00Z", Date.parse("2026-12-29T00:00:00Z")],
    ["2026-00-31T00:00:00Z", Date.parse("2025-12-29T00:00:00Z")],
    ["2026-10-00T00:00:00Z", NOW],
    ["2026-09-29T24:00:00Z", NOW],
    ["2026-09-29T01:60:00Z", NOW],
    ["2026-09-29T01:00:60Z", NOW]
  ]) {
    assert.throws(() => protocol.parseUsage({ seven_day: { percent: 2, resets_at: reset } }, now), reset);
  }
  for (const year of [2000, 2028]) {
    const reset = `${year}-02-29T05:30:00.123456789+05:30`;
    const result = protocol.parseUsage({ seven_day: { percent: 2, resets_at: reset } },
      Date.parse(`${year}-02-27T00:00:00Z`));
    assert.equal(result.weekly.resetAt, `${year}-02-29T00:00:00.123Z`);
  }
});

test("malformed offsets, missing zones and excessive precision fail closed", () => {
  for (const reset of [
    "2026-10-03T00:00:00+24:00", "2026-10-03T00:00:00-24:00",
    "2026-10-03T00:00:00+00:60", "2026-10-03T00:00:00-00:60",
    "2026-10-03T00:00:00+0000", "2026-10-03T00:00:00+0:00",
    "2026-10-03T00:00:00", "2026-10-03T00:00:00.Z",
    "2026-10-03T00:00:00.1234567890Z", "2026-10-03T00:00:00Z\n",
    null, 1790985600000
  ]) {
    assert.throws(() => protocol.parseUsage({ seven_day: { percent: 2, resets_at: reset } }, NOW));
  }
});

test("offset normalization preserves required weekly and optional session time boundaries", () => {
  for (const [kind, legacy, last, over] of [
    ["weekly_all", "seven_day", "2026-10-07T09:00:00+09:00", "2026-10-07T09:00:00.001+09:00"],
    ["session", "five_hour", "2026-09-29T01:00:00-05:00", "2026-09-29T01:00:00.001-05:00"]
  ]) {
    for (const schema of ["legacy", "limits"]) {
      const parse = reset => {
        const row = { percent: 2, resets_at: reset };
        const usage = schema === "legacy"
          ? { seven_day: { percent: 2, resets_at: WEEKLY }, [legacy]: row }
          : { limits: [...(kind === "session" ? [{ kind: "weekly_all", percent: 2, resets_at: WEEKLY }] : []),
            { kind, ...row }] };
        return protocol.parseUsage(usage, NOW);
      };
      assert.doesNotThrow(() => parse(last));
      assert.doesNotThrow(() => parse("2026-09-29T09:00:00.001+09:00"));
      assert.throws(() => parse(over));
      for (const reset of ["2026-09-29T09:00:00+09:00", "2026-09-28T17:00:00-07:00",
        "2026-09-29T08:59:59.999999999+09:00", "2026-09-29T09:00:00.000999999+09:00"]) {
        if (kind === "session") assert.equal(parse(reset).fiveHour, null);
        else assert.throws(() => parse(reset));
      }
    }
  }
});

test("invalid, elapsed, too-distant, and nonfinite windows fail closed", () => {
  for (const reset of [
    "2026-02-30T01:00:00Z", "2026-09-28T23:00:00Z", "2026-10-08T00:00:00Z"
  ]) {
    assert.throws(() => protocol.parseUsage({ seven_day: { utilization: 2, resets_at: reset } }, NOW));
  }
  assert.throws(() => protocol.parseUsage({ seven_day: { utilization: NaN, resets_at: WEEKLY } }, NOW));
  assert.throws(() => protocol.parseUsage({
    seven_day: { utilization: 2, resets_at: WEEKLY },
    five_hour: { utilization: 2, resets_at: "2026-09-29T07:00:00Z" }
  }, NOW));
});
