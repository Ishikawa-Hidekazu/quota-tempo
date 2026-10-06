import { normalizeUsage } from "./producer.mjs";

export const MAX_BYTES = 16 * 1024;
export const MAX_AGE_MS = 300_000;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const BASE_KEYS = ["schemaVersion", "connectionID", "streamID", "sequence", "result"];
const RESULT_KEYS = ["schemaVersion", "status", "reason", "readAt", "rateLimits"];
const ROW_KEYS = ["kind", "percentUsed", "resetsAt", "firstSeenAt", "lastReadAt"];
const REASONS = new Set([
  "invalid_read_at", "invalid_usage", "invalid_rate_limits", "invalid_limit",
  "unknown_kind", "duplicate_kind", "invalid_percent_used", "missing_reset",
  "invalid_reset", "expired_reset", "getter_failed", "clock_failed", "clock_regressed",
  "disconnected", "export_failed",
]);

function exactKeys(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function canonicalTime(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) && new Date(ms).toISOString() === value ? ms : null;
}

export function unixSocketPath(directory) {
  const prefix = "/private/tmp/qtc-";
  return typeof directory === "string" && directory.startsWith(prefix)
    && UUID.test(directory.slice(prefix.length)) ? `${directory}/bridge.sock` : null;
}

export function decodeGrant(text, now, directory) {
  try {
    if (typeof text !== "string" || text.length > 1024) return null;
    const grant = JSON.parse(text);
    const keys = ["schemaVersion", "purpose", "connectionID", "createdAt"];
    // Schema 1 is an explicitly experimental file receiver, never a fallback.
    // The former plaintext Unix transport (schema 2) is no longer accepted.
    if (grant.schemaVersion === 3) keys.push("transport", "socketPath");
    if (!exactKeys(grant, keys) || ![1, 3].includes(grant.schemaVersion)
      || grant.purpose !== "quotatempo-mods-comparison"
      || !UUID.test(grant.connectionID)) return null;
    if (grant.schemaVersion === 3 && (grant.transport !== "unix-hpke"
      || !unixSocketPath(directory) || grant.socketPath !== unixSocketPath(directory))) return null;
    const created = canonicalTime(grant.createdAt);
    if (created === null || !Number.isFinite(now) || created > now + 5000
      || now - created > 15 * 60_000) return null;
    return Object.freeze(grant);
  } catch { return null; }
}

export function encodeMessage({ connectionID, streamID, sequence, result }) {
  if (!UUID.test(connectionID) || !UUID.test(streamID) || !Number.isSafeInteger(sequence)
    || sequence < 1) throw new Error("invalid_message");
  return JSON.stringify({ schemaVersion: 1, connectionID, streamID, sequence, result });
}

/** Receives one explicitly chosen stream; never combines accounts or sources. */
export function createComparisonReceiver({ connectionID, streamID }) {
  if (!UUID.test(connectionID) || !UUID.test(streamID)) throw new Error("invalid_binding");
  let sequence = 0;
  let watermark = -Infinity;
  const empty = status => Object.freeze({
    status, identity: "unverified", sourceCapturedAt: null,
    automaticSelectionEligible: false, planningEligible: false, weekly: null, fiveHour: null,
  });

  return Object.freeze({
    consume(text, now) {
      try {
        if (!Number.isFinite(now) || now < watermark) return empty("invalid_clock");
        watermark = now;
        if (typeof text !== "string" || text.length > MAX_BYTES) return empty("invalid_message");
        const message = JSON.parse(text);
        if (!exactKeys(message, BASE_KEYS) || message.schemaVersion !== 1
          || message.connectionID !== connectionID || message.streamID !== streamID
          || !Number.isSafeInteger(message.sequence) || message.sequence <= sequence) {
          return empty("invalid_message");
        }
        const result = message.result;
        if (!exactKeys(result, RESULT_KEYS) || result.schemaVersion !== 1
          || !Array.isArray(result.rateLimits)) return empty("invalid_message");
        if (result.status !== "valid") {
          if (!["invalid", "unavailable"].includes(result.status)
            || !REASONS.has(result.reason) || result.rateLimits.length !== 0
            || (result.readAt !== null && canonicalTime(result.readAt) === null)) {
            return empty("invalid_message");
          }
          sequence = message.sequence;
          return empty(result.reason === "disconnected" ? "disconnected" : "unavailable");
        }
        const read = canonicalTime(result.readAt);
        if (read === null || read > now + 5000 || result.reason !== null) return empty("invalid_message");
        const normalized = normalizeUsage({ rateLimits: result.rateLimits }, result.readAt);
        if (normalized.status !== "valid") return empty("invalid_message");
        for (const row of result.rateLimits) {
          const first = canonicalTime(row.firstSeenAt);
          const last = canonicalTime(row.lastReadAt);
          const reset = canonicalTime(row.resetsAt);
          const maximum = row.kind === "seven_day" ? 691_200_000 : 21_600_000;
          if (!exactKeys(row, ROW_KEYS) || first === null || last !== read
            || first > read || reset === null || reset - read > maximum) return empty("invalid_message");
        }
        sequence = message.sequence;
        if (now - read > MAX_AGE_MS
          || result.rateLimits.some(row => now - Date.parse(row.firstSeenAt) > MAX_AGE_MS)) {
          return empty("stale");
        }
        if (result.rateLimits.some(row => Date.parse(row.resetsAt) <= now)) return empty("reset_passed");
        const window = kind => {
          const row = result.rateLimits.find(value => value.kind === kind);
          return row ? Object.freeze({ remainingPercent: 100 - row.percentUsed,
            resetAt: row.resetsAt, firstSeenAt: row.firstSeenAt, lastReadAt: row.lastReadAt }) : null;
        };
        return Object.freeze({ ...empty("comparison_only"), weekly: window("seven_day"),
          fiveHour: window("five_hour") });
      } catch { return empty("invalid_message"); }
    },
  });
}
