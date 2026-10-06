// Pure normalization for the isolated comparison probe; no shipped-app integration.
const KINDS = ["five_hour", "seven_day"];
const ISO_INSTANT = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$/;

function ownValue(object, key) {
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined;
}

function isRecord(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function instant(value) {
  if (typeof value !== "string" || value.length > 29) return null;
  const match = ISO_INSTANT.exec(value);
  if (!match) return null;
  const [, year, month, day, hour, minute, second, , zone] = match;
  const leap = +year % 4 === 0 && (+year % 100 !== 0 || +year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (+month < 1 || +month > 12 || +day < 1 || +day > days[+month - 1]
      || +hour > 23 || +minute > 59 || +second > 59) return null;
  if (zone !== "Z" && (+zone.slice(1, 3) > 23 || +zone.slice(4) > 59)) return null;
  // RFC 3339's -00:00 denotes an unknown offset, not a confirmed instant.
  if (zone === "-00:00") return null;
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) return null;
  const canonical = new Date(milliseconds).toISOString();
  return canonical.length === 24 ? canonical : null;
}

function envelope(status, reason, readAt, rateLimits = []) {
  return Object.freeze({
    schemaVersion: 1,
    status,
    reason,
    readAt,
    rateLimits: Object.freeze(rateLimits.map((limit) => Object.freeze(limit))),
  });
}

/** Normalize plain usage data; readAt is an injected local read time, not freshness. */
export function normalizeUsage(usage, readAt) {
  const timestamp = instant(readAt);
  if (timestamp === null) return envelope("invalid", "invalid_read_at", null);
  const invalid = (reason) => envelope("invalid", reason, timestamp);

  try {
    if (!isRecord(usage)) return invalid("invalid_usage");
    const limits = ownValue(usage, "rateLimits");
    if (!Array.isArray(limits) || limits.length < 1 || limits.length > KINDS.length) {
      return invalid("invalid_rate_limits");
    }

    const normalized = new Map();
    for (let index = 0; index < limits.length; index += 1) {
      const limit = ownValue(limits, String(index));
      if (!isRecord(limit)) return invalid("invalid_limit");
      const kind = ownValue(limit, "kind");
      if (!KINDS.includes(kind)) return invalid("unknown_kind");
      if (normalized.has(kind)) return invalid("duplicate_kind");

      const percentUsed = ownValue(limit, "percentUsed");
      if (typeof percentUsed !== "number" || !Number.isFinite(percentUsed)
          || percentUsed < 0 || percentUsed > 100) return invalid("invalid_percent_used");
      const resetValue = ownValue(limit, "resetsAt");
      if (resetValue === undefined) return invalid("missing_reset");
      const resetsAt = instant(resetValue);
      if (resetsAt === null) return invalid("invalid_reset");
      if (resetsAt <= timestamp) return invalid("expired_reset");

      normalized.set(kind, { kind, percentUsed: percentUsed === 0 ? 0 : percentUsed, resetsAt });
    }

    return envelope("valid", null, timestamp, KINDS.filter((kind) => normalized.has(kind))
      .map((kind) => normalized.get(kind)));
  } catch {
    // Never propagate input errors, field names, or arbitrary input content.
    return invalid("invalid_usage");
  }
}

/** One explicit poll, no scheduling or I/O beyond the injected callbacks. */
export function createUsageProducer({ getUsage, clock, sink }) {
  if (typeof getUsage !== "function" || typeof clock !== "function" || typeof sink !== "function") {
    throw new TypeError("getUsage, clock and sink must be functions");
  }

  let inFlight = false;
  let previous = new Map();
  let readWatermark = null;

  async function read() {
    let usage;
    try {
      usage = await getUsage();
    } catch {
      return envelope("unavailable", "getter_failed", null);
    }
    let readAt;
    try {
      readAt = clock();
    } catch {
      return envelope("unavailable", "clock_failed", null);
    }
    return normalizeUsage(usage, readAt);
  }

  return Object.freeze({
    async poll() {
      if (inFlight) throw new Error("poll_in_progress");
      inFlight = true;
      try {
        let result = await read();
        if (result.readAt !== null) {
          if (readWatermark !== null && result.readAt < readWatermark) {
            result = envelope("unavailable", "clock_regressed", result.readAt);
          } else {
            readWatermark = result.readAt;
          }
        }

        if (result.status === "valid") {
          const tracked = result.rateLimits.map((limit) => {
            const prior = previous.get(limit.kind);
            const unchanged = prior?.percentUsed === limit.percentUsed && prior.resetsAt === limit.resetsAt;
            return {
              kind: limit.kind,
              percentUsed: limit.percentUsed,
              resetsAt: limit.resetsAt,
              firstSeenAt: unchanged ? prior.firstSeenAt : result.readAt,
              lastReadAt: result.readAt,
            };
          });
          result = envelope("valid", null, result.readAt, tracked);
        }

        // Continuity follows local reads, even if sink delivery is uncertain.
        // Invalid reads and omitted kinds clear their old continuity entirely.
        previous = new Map(result.rateLimits.map((limit) => [limit.kind, limit]));
        try {
          await sink(result);
        } catch {
          throw new Error("sink_failed");
        }
        return result;
      } finally {
        inFlight = false;
      }
    },
  });
}
