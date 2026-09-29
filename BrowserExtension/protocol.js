(() => {
  "use strict";

  const ORIGIN = "https://claude.ai";
  const MAX_BODY_BYTES = 128 * 1024;
  const TIMEOUT_MS = 15_000;
  const EIGHT_DAYS_MS = 8 * 24 * 60 * 60 * 1000;
  const SIX_HOURS_MS = 6 * 60 * 60 * 1000;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

  class ObservationError extends Error {
    constructor(code) {
      super(code);
      this.code = code;
    }
  }

  function uuid(value) {
    if (typeof value !== "string" || !UUID.test(value)) throw new ObservationError("unavailable");
    return value.toLowerCase();
  }

  function accountUUID(data) {
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new ObservationError("unavailable");
    }
    const direct = data.uuid;
    const nested = data.account?.uuid;
    if (direct !== undefined && nested !== undefined && uuid(direct) !== uuid(nested)) {
      throw new ObservationError("unavailable");
    }
    return uuid(direct ?? nested);
  }

  function soleOrganizationUUID(data) {
    const organizations = Array.isArray(data) ? data : data?.organizations;
    if (!Array.isArray(organizations)) throw new ObservationError("unavailable");
    if (organizations.length !== 1) throw new ObservationError("organizationSelectionRequired");
    return uuid(organizations[0]?.uuid);
  }

  function resetAt(value, nowMs, maximumMs) {
    if (typeof value !== "string" || !UTC_ISO.test(value)) {
      throw new ObservationError("unavailable");
    }
    const parsed = Date.parse(value);
    if (!Number.isFinite(parsed) || parsed <= nowMs || parsed > nowMs + maximumMs) {
      throw new ObservationError("unavailable");
    }
    const normalized = new Date(parsed).toISOString();
    if (normalized.slice(0, 19) !== value.slice(0, 19)) {
      throw new ObservationError("unavailable");
    }
    return normalized;
  }

  function windowValue(row, nowMs, maximumMs) {
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new ObservationError("unavailable");
    }
    const raw = row.utilization ?? row.used_percentage;
    if (row.utilization !== undefined && row.used_percentage !== undefined) {
      throw new ObservationError("unavailable");
    }
    if (typeof raw !== "number" || !Number.isFinite(raw) || raw < 0 || raw > 100) {
      throw new ObservationError("unavailable");
    }
    return { remainingPercent: 100 - raw, resetAt: resetAt(row.resets_at, nowMs, maximumMs) };
  }

  function parseUsage(data, nowMs) {
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new ObservationError("unavailable");
    }
    if (data.limits !== undefined && !Array.isArray(data.limits)) {
      throw new ObservationError("unavailable");
    }
    const buckets = { weekly_all: [], session: [] };
    if (data.seven_day != null) buckets.weekly_all.push(data.seven_day);
    if (data.five_hour != null) buckets.session.push(data.five_hour);
    for (const limit of data.limits ?? []) {
      if (limit && Object.hasOwn(buckets, limit.kind)) buckets[limit.kind].push(limit);
    }
    if (buckets.weekly_all.length !== 1 || buckets.session.length > 1) {
      throw new ObservationError("unavailable");
    }
    return {
      weekly: windowValue(buckets.weekly_all[0], nowMs, EIGHT_DAYS_MS),
      fiveHour: buckets.session.length === 1
        ? windowValue(buckets.session[0], nowMs, SIX_HOURS_MS) : null
    };
  }

  async function sha256(value) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  }

  async function boundedJSON(response) {
    const declared = response.headers.get("content-length");
    if (declared !== null && Number(declared) > MAX_BODY_BYTES) {
      throw new ObservationError("unavailable");
    }
    if (!response.body) throw new ObservationError("unavailable");
    const reader = response.body.getReader();
    const chunks = [];
    let length = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > MAX_BODY_BYTES) {
          void reader.cancel().catch(() => {});
          throw new ObservationError("unavailable");
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    try {
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } catch {
      throw new ObservationError("unavailable");
    }
  }

  async function observe({ fetchImpl = fetch, now = () => Date.now(), timeoutMs = TIMEOUT_MS } = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const empty = status => ({
      status, accountFingerprint: null, organizationFingerprint: null,
      principalFingerprint: null, weekly: null, fiveHour: null
    });
    async function request(path) {
      const response = await fetchImpl(`${ORIGIN}${path}`, {
        method: "GET", credentials: "include", cache: "no-store", redirect: "error",
        signal: controller.signal
      });
      if (response.status === 401) throw new ObservationError("signedOut");
      if (response.status === 429) throw new ObservationError("rateLimited");
      if (!response.ok || response.redirected || response.url && new URL(response.url).origin !== ORIGIN) {
        throw new ObservationError("unavailable");
      }
      return boundedJSON(response);
    }
    try {
      const before = accountUUID(await request("/api/account"));
      const organization = soleOrganizationUUID(await request("/api/organizations"));
      const usage = await request(`/api/organizations/${organization}/usage`);
      const after = accountUUID(await request("/api/account"));
      if (before !== after) return empty("accountChanged");
      const windows = parseUsage(usage, now());
      return {
        status: "ok",
        accountFingerprint: await sha256(`claude-owner-v1:${before}:${organization}`),
        organizationFingerprint: await sha256(organization),
        principalFingerprint: await sha256(before),
        ...windows
      };
    } catch (error) {
      controller.abort();
      return empty(error instanceof ObservationError ? error.code : "unavailable");
    } finally {
      clearTimeout(timeout);
    }
  }

  const api = Object.freeze({ observe, parseUsage, accountUUID, soleOrganizationUUID });
  globalThis.QuotaProtocol = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})();
