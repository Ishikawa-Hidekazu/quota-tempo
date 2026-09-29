(() => {
  "use strict";
  if (globalThis.quotaTempoContentReady) return;
  globalThis.quotaTempoContentReady = true;

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.type !== "observe" || !/^[0-9a-f-]{36}$/i.test(message.requestID)) return;
    if (sender.id !== chrome.runtime.id || location.origin !== "https://claude.ai" || window !== top) {
      sendResponse({ accepted: false });
      return;
    }
    sendResponse({ accepted: true });
    QuotaProtocol.observe().then(result => {
      return chrome.runtime.sendMessage({
        type: "observation", requestID: message.requestID,
        observedAt: new Date(Date.now()).toISOString(), result
      });
    }).catch(() => {
      // The worker may have stopped or the tab may have closed. No response data is logged.
    });
  });
})();
