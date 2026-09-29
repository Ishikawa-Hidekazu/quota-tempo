"use strict";

const HOST = "co.ishikawa.quotatempo";
const WORKER_VERSION = "0.1.1";
const ALARM = "quotaTempoPoll";
const FIVE_MINUTES = 5 * 60 * 1000;
const MAX_BACKOFF = 60 * 60 * 1000;
const INFLIGHT_EXPIRY = 60 * 1000;
const REVOCATION_DELAYS = [15_000, 30_000, 60_000, 120_000];
const HASH = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUS = new Set([
  "ok", "signedOut", "accountChanged", "unavailable", "rateLimited",
  "organizationSelectionRequired", "disconnected"
]);
const DIAGNOSTICS = new Set([
  "accountRequest", "accountShape", "organizationsRequest", "organizationsShape",
  "usageRequest", "usageShape", "accountRecheckRequest", "accountRecheckShape",
  "fingerprint", "extensionDispatch", "workerValidation", "responseTimeout"
]);
let queue = Promise.resolve();

function serialize(action) {
  const next = queue.then(action);
  queue = next.catch(() => {});
  return next;
}

function initialState() {
  return {
    enabled: false, blocked: false, profileID: crypto.randomUUID(), tabID: null,
    pin: null, status: "disconnected", failureCount: 0, nextAt: null,
    lastFailureStage: null,
    lastObservedAt: null, inFlight: null, recovering: false, pendingDisconnect: false,
    pendingConnect: false, pendingConnectedMessage: null,
    connectionID: null, sequence: null, pendingRevocation: null
  };
}

async function state() {
  const stored = (await chrome.storage.local.get("bridgeState")).bridgeState;
  if (stored && UUID.test(stored.profileID)) {
    const value = {
      recovering: false, pendingDisconnect: false, pendingConnect: false,
      lastFailureStage: null,
      pendingConnectedMessage: null,
      connectionID: null, sequence: null, pendingRevocation: null, ...stored
    };
    return value;
  }
  const fresh = initialState();
  await save(fresh);
  return fresh;
}

async function save(value) {
  await chrome.storage.local.set({ bridgeState: value });
}

function view(value) {
  return {
    workerVersion: WORKER_VERSION,
    enabled: value.enabled, blocked: value.blocked, status: value.status,
    lastFailureStage: value.lastFailureStage,
    pinned: value.pin !== null, lastObservedAt: value.lastObservedAt,
    nextAt: value.nextAt, pendingDisconnect: value.pendingDisconnect,
    pendingConnect: value.pendingConnect
  };
}

function validPin(pin) {
  return pin && [pin.accountFingerprint, pin.organizationFingerprint, pin.principalFingerprint]
    .every(value => typeof value === "string" && HASH.test(value));
}

function claudeURL(url) {
  try { return new URL(url).origin === "https://claude.ai"; } catch { return false; }
}

function validWindow(value, now, maximum) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  if (typeof value.remainingPercent !== "number" || !Number.isFinite(value.remainingPercent)
    || value.remainingPercent < 0 || value.remainingPercent > 100) return false;
  if (typeof value.resetAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value.resetAt)) return false;
  const reset = Date.parse(value.resetAt);
  return Number.isFinite(reset) && new Date(reset).toISOString() === value.resetAt
    && reset > now && reset <= now + maximum;
}

function normalizedResult(input, now) {
  const empty = status => ({
    status, accountFingerprint: null, organizationFingerprint: null,
    principalFingerprint: null, weekly: null, fiveHour: null
  });
  if (!input || !STATUS.has(input.status) || input.status === "disconnected") {
    return empty("unavailable");
  }
  if (input.status !== "ok") return empty(input.status);
  if (![input.accountFingerprint, input.organizationFingerprint, input.principalFingerprint]
    .every(value => typeof value === "string" && HASH.test(value))) return empty("unavailable");
  if (!validWindow(input.weekly, now, 8 * 24 * 60 * 60 * 1000)) return empty("unavailable");
  if (input.fiveHour !== null && !validWindow(input.fiveHour, now, 6 * 60 * 60 * 1000)) {
    return empty("unavailable");
  }
  return {
    status: "ok", accountFingerprint: input.accountFingerprint,
    organizationFingerprint: input.organizationFingerprint,
    principalFingerprint: input.principalFingerprint,
    weekly: { remainingPercent: input.weekly.remainingPercent, resetAt: input.weekly.resetAt },
    fiveHour: input.fiveHour === null ? null : {
      remainingPercent: input.fiveHour.remainingPercent, resetAt: input.fiveHour.resetAt
    }
  };
}

function envelope(value, result, observedAt = new Date(Date.now()).toISOString()) {
  return {
    schemaVersion: 1, profileID: value.profileID, connectionID: value.connectionID,
    sequence: value.sequence, observedAt, ...result
  };
}

function validGeneration(value) {
  return UUID.test(value.connectionID) && Number.isSafeInteger(value.sequence)
    && value.sequence >= 0;
}

async function sendNext(value, result, observedAt, retryable = false) {
  if (!validGeneration(value) || value.sequence >= Number.MAX_SAFE_INTEGER) {
    value.status = "connectRequired";
    value.enabled = false;
    value.pendingDisconnect = false;
    await save(value);
    return "nativeRejected";
  }
  value.sequence += 1;
  const message = envelope(value, result, observedAt);
  if (retryable) {
    value.pendingRevocation = { message, retryCount: 0 };
  }
  await save(value);
  const ack = await nativeSend(message);
  value.lastObservedAt = message.observedAt;
  if (ack === "ok" && retryable) value.pendingRevocation = null;
  await save(value);
  return ack;
}

async function retryRevocation(value, explicit = false) {
  const pending = value.pendingRevocation;
  if (!pending) return "ok";
  if (!explicit && pending.retryCount >= REVOCATION_DELAYS.length) return "nativeUnavailable";
  const ack = await nativeSend(pending.message);
  if (ack === "ok") {
    value.pendingRevocation = null;
  } else {
    if (!explicit) pending.retryCount += 1;
  }
  await save(value);
  return ack;
}

async function scheduleRevocationRetry(value) {
  const pending = value.pendingRevocation;
  if (!pending || pending.retryCount >= REVOCATION_DELAYS.length) {
    value.nextAt = null;
    value.status = "nativeUnavailable";
    await save(value);
    await stopPolling();
    return;
  }
  await schedule(value, REVOCATION_DELAYS[pending.retryCount]);
}

async function nativeSend(message) {
  try {
    const ack = await chrome.runtime.sendNativeMessage(HOST, message);
    if (ack?.ok === true) return "ok";
    if (ack?.ok === false && (ack.error === undefined
      || typeof ack.error === "string" && /^[a-z][a-zA-Z0-9]{0,63}$/.test(ack.error))) {
      return "nativeRejected";
    }
    return "nativeRejected";
  } catch {
    return "nativeUnavailable";
  }
}

async function schedule(value, delay) {
  value.nextAt = Date.now() + delay;
  await save(value);
  await chrome.alarms.create(ALARM, { when: value.nextAt });
}

async function stopPolling() {
  await chrome.alarms.clear(ALARM);
}

function nextDelay(value, status) {
  if (status === "ok") return FIVE_MINUTES;
  const base = status === "rateLimited" ? 15 * 60 * 1000 : FIVE_MINUTES;
  return Math.min(MAX_BACKOFF, base * 2 ** Math.min(value.failureCount - 1, 4));
}

async function finishObservation(value, result, observedAt = new Date(Date.now()).toISOString()) {
  const now = Date.now();
  let checked = normalizedResult(result, now);
  value.lastFailureStage = checked.status === "unavailable"
    ? (DIAGNOSTICS.has(result?.diagnostic) ? result.diagnostic : "workerValidation") : null;
  if (checked.status === "ok") {
    const candidate = {
      accountFingerprint: checked.accountFingerprint,
      organizationFingerprint: checked.organizationFingerprint,
      principalFingerprint: checked.principalFingerprint
    };
    if (value.pin === null) value.pin = candidate;
    else if (Object.keys(candidate).some(key => candidate[key] !== value.pin[key])) {
      checked = normalizedResult({ status: "accountChanged" }, now);
    }
  }
  const waitingForPinnedAccount = value.recovering && checked.status === "accountChanged";
  if (waitingForPinnedAccount) value.tabID = null;
  if (value.recovering && checked.status === "ok") value.recovering = false;
  const revocation = checked.status === "accountChanged";
  const ack = await sendNext(value, checked, observedAt, revocation);
  value.inFlight = null;
  value.status = ack === "ok"
    ? (waitingForPinnedAccount ? "waitingForAccount" : checked.status) : ack;
  value.blocked = checked.status === "accountChanged" && !value.recovering
    || checked.status === "organizationSelectionRequired";
  if (revocation && ack !== "ok") {
    await scheduleRevocationRetry(value);
    return;
  }
  if (!value.enabled || value.blocked) {
    value.nextAt = null;
    await save(value);
    await stopPolling();
    return;
  }
  value.failureCount = checked.status === "ok" && ack === "ok" ? 0 : value.failureCount + 1;
  await schedule(value, nextDelay(value, checked.status === "ok" && ack !== "ok" ? "unavailable" : checked.status));
}

async function observationIsDeferred(value) {
  if (value.inFlight) {
    if (value.inFlight.expiresAt <= Date.now()) {
      await finishObservation(value, { status: "unavailable", diagnostic: "responseTimeout" });
    }
    return true;
  }
  if (value.failureCount > 0 && value.nextAt > Date.now()) {
    await save(value);
    await chrome.alarms.create(ALARM, { when: value.nextAt });
    return true;
  }
  return false;
}

async function startObservation(value) {
  if (!value.enabled || value.blocked || !Number.isInteger(value.tabID)) return;
  if (await observationIsDeferred(value)) return;
  let tab;
  try { tab = await chrome.tabs.get(value.tabID); } catch { /* Tab no longer exists. */ }
  if (!tab || !claudeURL(tab.url)) {
    value.tabID = null;
    value.recovering = true;
    value.status = "waitingForTab";
    await schedule(value, FIVE_MINUTES);
    return;
  }
  const requestID = crypto.randomUUID();
  value.inFlight = { requestID, tabID: value.tabID, expiresAt: Date.now() + INFLIGHT_EXPIRY };
  await save(value);
  await chrome.alarms.create(ALARM, { when: value.inFlight.expiresAt });
  try {
    await chrome.scripting.executeScript({
      target: { tabId: value.tabID, allFrames: false },
      files: ["protocol.js", "content.js"], world: "ISOLATED"
    });
    const reply = await chrome.tabs.sendMessage(value.tabID, { type: "observe", requestID }, { frameId: 0 });
    if (reply?.accepted !== true) throw new Error("notAccepted");
  } catch {
    await finishObservation(value, { status: "unavailable", diagnostic: "extensionDispatch" });
  }
}

async function rebind(value) {
  if (!value.enabled || value.blocked || value.pendingDisconnect || value.pendingConnect
    || value.pendingRevocation) return;
  if (!validPin(value.pin) || !validGeneration(value)) {
    value.blocked = true;
    value.status = "connectRequired";
    value.nextAt = null;
    await save(value);
    await stopPolling();
    return;
  }
  if (await observationIsDeferred(value)) return;
  let tab;
  if (Number.isInteger(value.tabID)) {
    try { tab = await chrome.tabs.get(value.tabID); } catch { /* Restored tab IDs can change. */ }
    if (!claudeURL(tab?.url)) tab = undefined;
  }
  if (!tab) {
    const candidates = (await chrome.tabs.query({ url: "https://claude.ai/*" }))
      .filter(candidate => claudeURL(candidate.url));
    if (candidates.length === 1) tab = candidates[0];
  }
  if (!tab) {
    value.tabID = null;
    value.inFlight = null;
    value.recovering = true;
    value.status = "waitingForTab";
    await schedule(value, FIVE_MINUTES);
    return;
  }
  value.tabID = tab.id;
  value.recovering = true;
  value.status = "reconnecting";
  await save(value);
  await startObservation(value);
}

async function sendPendingDisconnect(value) {
  if (!value.pendingDisconnect) return "ok";
  const disconnected = normalizedResult({ status: "disconnected" }, Date.now());
  disconnected.status = "disconnected";
  const ack = value.pendingRevocation?.message.status === "disconnected"
    ? await retryRevocation(value, true)
    : await sendNext(value, disconnected, undefined, true);
  value.pendingDisconnect = ack !== "ok";
  value.status = ack === "ok" ? "disconnected" : ack;
  if (ack === "ok") {
    value.pin = null;
    value.connectionID = null;
    value.sequence = null;
    value.pendingRevocation = null;
  }
  await save(value);
  return ack;
}

async function connect(reconnect) {
  const value = await state();
  if (value.enabled && !reconnect && !value.pendingDisconnect) return view(value);
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !claudeURL(tab.url)) return { error: "claudeTabRequired" };
  if (value.pendingConnect) {
    if (!value.pendingConnectedMessage || !validGeneration(value)
      || value.sequence !== 0) return { error: "connectRequired" };
    const ack = await nativeSend(value.pendingConnectedMessage);
    if (ack !== "ok") {
      value.status = ack;
      await save(value);
      return view(value);
    }
    value.pendingConnect = false;
    value.pendingConnectedMessage = null;
    value.enabled = true;
    value.tabID = tab.id;
    value.status = "connecting";
    await save(value);
    await startObservation(value);
    return view(value);
  }
  if (value.enabled && reconnect) {
    value.enabled = false;
    value.recovering = false;
    value.inFlight = null;
    value.tabID = null;
    value.pendingDisconnect = true;
    await save(value);
    await stopPolling();
  }
  if (value.pendingDisconnect && await sendPendingDisconnect(value) !== "ok") return view(value);
  await stopPolling();
  value.enabled = false;
  value.blocked = false;
  value.tabID = tab.id;
  value.pin = null;
  value.status = "connecting";
  value.lastFailureStage = null;
  value.failureCount = 0;
  value.nextAt = null;
  value.inFlight = null;
  value.recovering = false;
  value.pendingDisconnect = false;
  value.pendingConnect = true;
  value.connectionID = crypto.randomUUID();
  value.sequence = 0;
  value.pendingRevocation = null;
  const connected = normalizedResult({ status: "connected" }, Date.now());
  connected.status = "connected";
  const message = envelope(value, connected);
  value.pendingConnectedMessage = message;
  await save(value);
  const ack = await nativeSend(message);
  value.lastObservedAt = message.observedAt;
  if (ack !== "ok") {
    value.status = ack;
    await save(value);
    return view(value);
  }
  value.pendingConnect = false;
  value.pendingConnectedMessage = null;
  value.enabled = true;
  await save(value);
  await startObservation(value);
  return view(value);
}

async function disconnect() {
  const value = await state();
  if (!value.enabled && !value.pendingDisconnect && !value.pendingConnect) return view(value);
  if (value.pendingConnect) {
    if (!value.pendingConnectedMessage) return { error: "connectRequired" };
    const connectedAck = await nativeSend(value.pendingConnectedMessage);
    if (connectedAck !== "ok") {
      value.status = connectedAck;
      await save(value);
      return view(value);
    }
  }
  value.enabled = false;
  value.blocked = false;
  value.tabID = null;
  value.status = "disconnecting";
  value.inFlight = null;
  value.nextAt = null;
  value.failureCount = 0;
  value.recovering = false;
  value.pendingDisconnect = true;
  value.pendingConnect = false;
  value.pendingConnectedMessage = null;
  await save(value);
  await stopPolling();
  await sendPendingDisconnect(value);
  return view(value);
}

async function handle(message, sender) {
  if (sender.id !== chrome.runtime.id) return { error: "invalidSender" };
  if (message?.type === "state" && !sender.tab) return view(await state());
  if (message?.type === "connect" && !sender.tab) return connect(false);
  if (message?.type === "reconnect" && !sender.tab) return connect(true);
  if (message?.type === "disconnect" && !sender.tab) return disconnect();
  if (message?.type !== "observation") return { error: "invalidMessage" };
  const value = await state();
  if (!value.enabled || !value.inFlight || message.requestID !== value.inFlight.requestID
    || value.inFlight.expiresAt <= Date.now()) {
    return { accepted: false };
  }
  if (sender.frameId !== 0 || sender.tab?.id !== value.tabID
    || sender.tab.id !== value.inFlight.tabID || !claudeURL(sender.url)
    || !claudeURL(sender.tab.url) || sender.origin && sender.origin !== "https://claude.ai") {
    return { accepted: false };
  }
  const observed = Date.parse(message.observedAt);
  if (typeof message.observedAt !== "string" || !Number.isFinite(observed)
    || new Date(observed).toISOString() !== message.observedAt
    || observed > Date.now() || observed < value.inFlight.expiresAt - INFLIGHT_EXPIRY
    || observed > value.inFlight.expiresAt) {
    return { accepted: false };
  }
  await finishObservation(value, message.result, message.observedAt);
  return { accepted: true };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  serialize(() => handle(message, sender)).then(sendResponse, () => sendResponse({ error: "unavailable" }));
  return true;
});

chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name !== ALARM) return;
  serialize(async () => {
    const value = await state();
    if (value.pendingRevocation?.message.status === "accountChanged") {
      const ack = await retryRevocation(value);
      if (ack !== "ok") await scheduleRevocationRetry(value);
      else {
        value.nextAt = null;
        value.status = value.recovering ? "waitingForAccount" : "accountChanged";
        await save(value);
        await stopPolling();
        if (value.recovering) await rebind(value);
      }
      return;
    }
    if (!value.enabled || value.blocked) return;
    if (value.recovering) await rebind(value);
    else await startObservation(value);
  });
});

chrome.runtime.onStartup.addListener(() => {
  serialize(async () => {
    const value = await state();
    await stopPolling();
    if (value.pendingConnect) return;
    if (!value.enabled) return;
    value.inFlight = null;
    if (value.failureCount === 0) value.nextAt = null;
    value.recovering = true;
    if (value.pendingRevocation?.message.status === "accountChanged") {
      await scheduleRevocationRetry(value);
      return;
    }
    await rebind(value);
  });
});

chrome.tabs.onUpdated.addListener((_tabID, changeInfo, tab) => {
  if (!claudeURL(changeInfo.url ?? tab.url)) return;
  serialize(async () => {
    const value = await state();
    if (value.enabled && value.recovering) await rebind(value);
  });
});

chrome.tabs.onRemoved.addListener(tabID => {
  serialize(async () => {
    const value = await state();
    if (!value.enabled) return;
    if (value.tabID === tabID) {
      value.tabID = null;
      value.inFlight = null;
      value.recovering = true;
      await save(value);
    }
    if (value.recovering) await rebind(value);
  });
});
