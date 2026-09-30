(() => {
  "use strict";

  const ORIGIN = "https://claude.ai";
  const MAX_BODY_BYTES = 128 * 1024;
  const TIMEOUT_MS = 15_000;
  const EIGHT_DAYS_MS = 8 * 24 * 60 * 60 * 1000;
  const SIX_HOURS_MS = 6 * 60 * 60 * 1000;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const RESET_ISO = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|([+-])(\d{2}):(\d{2}))$/;

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

  function accountIdentity(data) {
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new ObservationError("unavailable");
    }
    if (data.uuid !== undefined || data.account?.uuid !== undefined) {
      return accountUUID(data);
    }
    const direct = data.email_address;
    const nested = data.account?.email_address;
    if (direct !== undefined && nested !== undefined && direct !== nested) {
      throw new ObservationError("unavailable");
    }
    const email = direct ?? nested;
    if (typeof email !== "string" || email.length > 254
      || !/^[^\s@]+@[^\s@]+$/.test(email)) {
      throw new ObservationError("unavailable");
    }
    return `email:${email.toLowerCase()}`;
  }

  function soleOrganizationUUID(data) {
    const organizations = Array.isArray(data) ? data : data?.organizations;
    if (!Array.isArray(organizations)) throw new ObservationError("unavailable");
    if (organizations.length !== 1) throw new ObservationError("organizationSelectionRequired");
    return uuid(organizations[0]?.uuid);
  }

  function resetAt(value, nowMs, maximumMs) {
    const match = typeof value === "string" ? RESET_ISO.exec(value) : null;
    if (!match || match[0] !== value) {
      throw new ObservationError("unavailable");
    }
    const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
    const milliseconds = Number((match[7] ?? "").padEnd(3, "0").slice(0, 3));
    const offsetHours = Number(match[10] ?? 0);
    const offsetMinutes = Number(match[11] ?? 0);
    if (offsetHours > 23 || offsetMinutes > 59) {
      throw new ObservationError("unavailable");
    }
    // Validate local calendar fields before applying the offset; Date setters normalize overflow.
    const local = new Date(0);
    local.setUTCFullYear(year, month - 1, day);
    local.setUTCHours(hour, minute, second, milliseconds);
    if (local.toISOString().slice(0, 19) !== value.slice(0, 19)) {
      throw new ObservationError("unavailable");
    }
    const offsetMs = (offsetHours * 60 + offsetMinutes) * 60_000 * (match[9] === "-" ? -1 : 1);
    const parsed = local.getTime() - offsetMs;
    if (!Number.isFinite(parsed) || parsed > nowMs + maximumMs) {
      throw new ObservationError("unavailable");
    }
    return new Date(parsed).toISOString();
  }

  function windowValue(row, nowMs, maximumMs) {
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new ObservationError("unavailable");
    }
    const keys = ["utilization", "used_percentage", "percent"].filter(key => Object.hasOwn(row, key));
    if (keys.length !== 1) {
      throw new ObservationError("unavailable");
    }
    const raw = row[keys[0]];
    if (typeof raw !== "number" || !Number.isFinite(raw) || raw < 0 || raw > 100) {
      throw new ObservationError("unavailable");
    }
    return { remainingPercent: 100 - raw, resetAt: resetAt(row.resets_at, nowMs, maximumMs) };
  }

  function mergedWindow(legacy, limits, nowMs, maximumMs, optional = false) {
    if (limits.length > 1) throw new ObservationError("unavailable");
    const oldWindow = legacy == null ? null : windowValue(legacy, nowMs, maximumMs);
    const newWindow = limits.length === 0 ? null : windowValue(limits[0], nowMs, maximumMs);
    if (oldWindow && newWindow
      && (oldWindow.remainingPercent !== newWindow.remainingPercent || oldWindow.resetAt !== newWindow.resetAt)) {
      throw new ObservationError("unavailable");
    }
    const window = oldWindow ?? newWindow;
    // Validate both schemas before omitting an elapsed optional window. Never extend its reset.
    if (window && Date.parse(window.resetAt) <= nowMs) {
      if (optional) return null;
      throw new ObservationError("unavailable");
    }
    return window;
  }

  function parseUsage(data, nowMs) {
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new ObservationError("unavailable");
    }
    if (data.limits !== undefined && !Array.isArray(data.limits)) {
      throw new ObservationError("unavailable");
    }
    const buckets = { weekly_all: [], session: [] };
    for (const limit of data.limits ?? []) {
      if (limit && Object.hasOwn(buckets, limit.kind)) buckets[limit.kind].push(limit);
    }
    const weekly = mergedWindow(data.seven_day, buckets.weekly_all, nowMs, EIGHT_DAYS_MS);
    if (!weekly) throw new ObservationError("unavailable");
    return {
      weekly,
      fiveHour: mergedWindow(data.five_hour, buckets.session, nowMs, SIX_HOURS_MS, true)
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
    let phase = "accountRequest";
    let verifiedIdentity = null;
    const empty = status => ({
      status, diagnostic: status === "unavailable" ? phase : null,
      accountFingerprint: null, organizationFingerprint: null,
      principalFingerprint: null, weekly: null, fiveHour: null,
      ...(status === "unavailable" ? verifiedIdentity : null)
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
      const accountBefore = await request("/api/account");
      phase = "accountShape";
      const before = accountIdentity(accountBefore);
      phase = "organizationsRequest";
      const organizations = await request("/api/organizations");
      phase = "organizationsShape";
      const organization = soleOrganizationUUID(organizations);
      phase = "usageRequest";
      const usage = await request(`/api/organizations/${organization}/usage`);
      phase = "accountRecheckRequest";
      const accountAfter = await request("/api/account");
      phase = "accountRecheckShape";
      const after = accountIdentity(accountAfter);
      if (before !== after) return empty("accountChanged");
      phase = "fingerprint";
      // Retain only rechecked ownership hashes when usage is invalid, so the worker can revoke an old pin.
      verifiedIdentity = {
        accountFingerprint: await sha256(`claude-owner-v1:${before}:${organization}`),
        organizationFingerprint: await sha256(organization),
        principalFingerprint: await sha256(before)
      };
      phase = "usageShape";
      const windows = parseUsage(usage, now());
      return { status: "ok", ...verifiedIdentity, ...windows };
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
