"use strict";

const POPUP_VERSION = "0.1.2";
let workerVersion = null;
const versionNode = document.getElementById("version");
const statusNode = document.getElementById("status");
const detailNode = document.getElementById("detail");
const connectButton = document.getElementById("connect");
const reconnectButton = document.getElementById("reconnect");
const disconnectButton = document.getElementById("disconnect");

const labels = {
  connecting: ["Connecting", "Waiting for the QuotaTempo host to confirm this connection."],
  reconnecting: ["Reconnecting", "Checking an existing Claude tab against the pinned account."],
  waitingForTab: ["Waiting for Claude tab", "An existing Claude tab will be checked when it appears."],
  waitingForAccount: ["Different account", "The pinned account must be available, or reconnect explicitly."],
  connectRequired: ["Connect required", "The saved connection cannot be restored safely."],
  disconnecting: ["Disconnecting", "Waiting for the QuotaTempo host to confirm."],
  ok: ["Connected", "Observation delivered to QuotaTempo."],
  signedOut: ["Signed out", "Sign in on the selected Claude tab, then reconnect."],
  accountChanged: ["Account changed", "Reconnect to approve the new account."],
  unavailable: ["Unavailable", "The selected Claude tab did not provide a valid observation."],
  rateLimited: ["Rate limited", "The next attempt is delayed."],
  organizationSelectionRequired: ["Organization selection required", "This prototype connects only when exactly one organization is available."],
  disconnected: ["Disconnected", ""],
  nativeUnavailable: ["Host unavailable", "The QuotaTempo native host is not responding."],
  nativeRejected: ["Host rejected message", "The native connection state needs verification."]
};

function render(value) {
  if (typeof value?.workerVersion === "string" && /^\d+\.\d+\.\d+$/.test(value.workerVersion)) {
    workerVersion = value.workerVersion;
  }
  versionNode.textContent = `Bridge ${POPUP_VERSION} / worker ${workerVersion ?? "unknown"}`;
  const [title, detail] = labels[value?.status] ?? labels.unavailable;
  statusNode.textContent = title;
  detailNode.textContent = value?.pendingDisconnect
    ? "Disconnect is unconfirmed. Connect retries that handshake before creating a new connection."
    : workerVersion !== POPUP_VERSION
      ? "Reload QuotaTempo in chrome://extensions, then reopen this popup."
    : value?.status === "unavailable" && value?.lastFailureStage
      ? `Acquisition stopped at ${value.lastFailureStage}.` : detail;
  connectButton.hidden = value?.enabled === true;
  reconnectButton.hidden = value?.enabled !== true;
  disconnectButton.hidden = value?.enabled !== true && value?.pendingDisconnect !== true;
}

async function command(type) {
  for (const button of [connectButton, reconnectButton, disconnectButton]) button.disabled = true;
  try {
    const reply = await chrome.runtime.sendMessage({ type });
    if (reply?.error === "claudeTabRequired") {
      statusNode.textContent = "Claude tab required";
      detailNode.textContent = "Open this popup on an existing claude.ai tab.";
    } else if (reply?.error) {
      render({ status: "unavailable", enabled: false });
    } else {
      render(reply);
    }
  } catch {
    render({ status: "unavailable", enabled: false });
  } finally {
    for (const button of [connectButton, reconnectButton, disconnectButton]) button.disabled = false;
  }
}

connectButton.addEventListener("click", () => command("connect"));
reconnectButton.addEventListener("click", () => command("reconnect"));
disconnectButton.addEventListener("click", () => command("disconnect"));
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.bridgeState) {
    const value = changes.bridgeState.newValue;
    render({ status: value.status, enabled: value.enabled,
      pendingDisconnect: value.pendingDisconnect, lastFailureStage: value.lastFailureStage });
  }
});
command("state");
