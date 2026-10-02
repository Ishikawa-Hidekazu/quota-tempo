# Synthetic Claude Mods usage producer

Experimental, synthetic-only, and **not connected to the shipped app**. Nothing
is installed or registered. There is no mod adapter, plugin manifest, CLI,
transport, scheduler, persistent store, or live provider access here.

This implements only the supplied `$.session.usage()` data contract:
`{ rateLimits: [{ kind, percentUsed, resetsAt? }] }`. Runtime compatibility and
provider permission have not been verified.

## API

- `normalizeUsage(usage, readAt)` is pure. Pass a plain data object and a local
  ISO timestamp. It returns a frozen, allowlisted result.
- `createUsageProducer({ getUsage, clock, sink })` returns `{ poll() }`.
  `getUsage()` may return data or a promise. `clock()` synchronously returns an
  ISO string, sampled after the getter resolves. `sink(result)` may be async.
  All three callbacks are required; construction performs no work.
- `await producer.poll()` performs one read and one sink call, then returns the
  same frozen result. It does not retry. Concurrent calls reject with the fixed
  error `poll_in_progress`, including while the sink is pending.

The producer imports nothing and has no process, file, network, command, or
default-clock access. The caller controls the injected capabilities. Only fake
callbacks are used in this directory. No external JSON fixtures are read.

## Fixed output

Every result contains only `schemaVersion: 1`, `status`, `reason`, `readAt`, and
`rateLimits`. Status is `valid`, `invalid`, or `unavailable`; reason is null or a
fixed code defined in the producer, never raw input/error text.

Normalized rows contain only `kind`, `percentUsed`, and `resetsAt`. Producer rows
also contain `firstSeenAt` and `lastReadAt`. Unknown input fields are ignored
without enumeration, evaluation, or copying. Session/account identifiers, paths,
models, arbitrary text, and upstream freshness fields never enter the output.
Known fields must be own data properties. Outputs do not retain input objects.

- Accept one or two unique kinds: `five_hour` and `seven_day`, in that output
  order. Empty arrays, duplicates, unknown kinds, malformed rows, or more than
  two rows invalidate the entire read.
- Percentages must be finite numbers in the inclusive range 0 through 100.
  There is no coercion, clamping, rounding, or estimation.
- Although `resetsAt` is optional in the input contract, every accepted row must
  supply a strictly future reset relative to `readAt`. Missing, empty, malformed,
  or expired resets invalidate the entire read. No prior reset is borrowed.
- Timestamps require a four-digit calendar year, valid date, `T`, seconds, and
  `Z` or a numeric offset. Fractional seconds may have one to three digits.
  Date-only/local times, calendar rollover, leap seconds, `24:00`, unknown
  `-00:00` offsets, and finer precision are rejected, not guessed or truncated.
  Valid instants are normalized to UTC milliseconds with a four-digit year.
- A valid subset remains a subset: a five-hour row alone never supplies a weekly
  quota or reset. Invalid reads and omitted kinds clear prior continuity.

## Observation boundaries

`readAt` and `lastReadAt` are local read times, **not server freshness**.
`firstSeenAt` is the first local read of the current unchanged `(kind,
percentUsed, resetsAt)` tuple within uninterrupted valid reads. Identical polls
retain it, including reordered rows and equivalent timestamp spellings. A
percentage change or reset change starts a new local tuple. Equal timestamps
are allowed, so `firstSeenAt` is not a unique event ID.

A changed reset replaces old window continuity even when percentage usage is
unchanged. Identical data becomes invalid once its reset expires. No reset
extrapolation, counter-based freshness, server observation timestamp, ownership
proof, or account continuity is claimed. Identical tuples could be stale or
belong to different accounts; the producer cannot distinguish them. `valid`
means schema/time checks passed, **not verified exact provider truth** and not
permission to use this data as shipped-app freshness or planning evidence.

Getter/clock failures emit a fixed `unavailable` result with no quota rows.
Invalid clocks fail validation; clock regressions fail closed and never lower
the local watermark. Sink failures reject with `sink_failed` without the original
error or cause. Local continuity is committed before sink delivery: a sink can
accept data and then throw, so delivery is uncertain and there is no automatic
replay. Consumers must replace/invalidate prior display state on an empty result,
not retain it as a current observation.

State is bounded to two rows, one watermark, and one in-flight poll, in memory
only. Restarting creates new local first-seen times, not refreshed server data.
A pending injected callback has no built-in timeout or cancellation; a future
adapter must define those boundaries. Plain data inputs are expected; this is
not a sandbox for hostile executable JavaScript or Proxy traps.

## Verification

From the repository root, using only Node's built-in test runner:

```sh
node --test experiments/claude-mods-usage/producer.test.mjs
```

Tests use inline synthetic objects and fake getters, clocks, and sinks only.
They do not run Swift, Claude, plugins, real files as input, or live providers.
Any future adapter/harness, installation, transport, policy decision, account
binding, and native acceptance require separate scoped work and verification.
