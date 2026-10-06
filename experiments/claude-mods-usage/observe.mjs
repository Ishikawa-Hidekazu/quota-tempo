import { performance } from "node:perf_hooks";
import { setTimeout as delay } from "node:timers/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createComparisonReceiver, MAX_AGE_MS, UUID } from "./protocol.mjs";
import { readStreamRecord } from "./receiver.mjs";

const empty = status => Object.freeze({ status, identity: "unverified", sourceCapturedAt: null,
  automaticSelectionEligible: false, planningEligible: false, weekly: null, fiveHour: null });

function expire(view, now) {
  const windows = [view.weekly, view.fiveHour].filter(Boolean);
  if (windows.some(row => now - Date.parse(row.firstSeenAt) > MAX_AGE_MS
    || now - Date.parse(row.lastReadAt) > MAX_AGE_MS)) return empty("stale");
  if (windows.some(row => Date.parse(row.resetAt) <= now)) return empty("reset_passed");
  return view;
}

/** One process, one explicitly selected stream. Rereads never become observations. */
export function createStreamObserver({ streamID, readRecord }) {
  if (!UUID.test(streamID) || typeof readRecord !== "function") throw new Error("invalid_binding");
  let receiver = null;
  let connectionID = null;
  let lastText = null;
  let view = empty("waiting_for_measurement");
  let watermark = -Infinity;
  let busy = false;
  return Object.freeze({
    async sample(clock = Date.now) {
      if (busy) throw new Error("observation_in_progress");
      busy = true;
      try {
        const now = typeof clock === "function" ? clock() : clock;
        if (!Number.isFinite(now) || now < watermark) {
          view = empty("invalid_clock");
          return view;
        }
        watermark = now;
        const record = await readRecord();
        const completedAt = typeof clock === "function" ? clock() : clock;
        if (!Number.isFinite(completedAt) || completedAt < watermark) {
          view = empty("invalid_clock");
          return view;
        }
        watermark = completedAt;
        if (record.streamID !== streamID || !UUID.test(record.connectionID)) {
          view = empty("invalid_binding");
          return view;
        }
        if (receiver && record.connectionID !== connectionID) {
          view = empty("connection_changed");
          return view;
        }
        if (!receiver) {
          connectionID = record.connectionID;
          receiver = createComparisonReceiver({ connectionID, streamID });
        }
        if (record.message !== lastText) {
          view = receiver.consume(record.message, completedAt);
          lastText = typeof record.message === "string" ? record.message : null;
        } else {
          view = expire(view, completedAt);
        }
        return view;
      } catch {
        // Do not renew or restore the last value after an unreadable/partial file.
        view = empty(receiver ? "stream_unavailable" : "waiting_for_measurement");
        return view;
      } finally { busy = false; }
    },
  });
}

export async function observeStream(directory, streamID, durationSeconds, { signal, emit } = {}) {
  if (!UUID.test(streamID) || !Number.isInteger(durationSeconds) || durationSeconds < 1
    || durationSeconds > 1800 || typeof emit !== "function") throw new Error("invalid_observation");
  const observer = createStreamObserver({ streamID, readRecord: () => readStreamRecord(directory, streamID) });
  const deadline = performance.now() + durationSeconds * 1000;
  let lastOutput = null;
  while (!signal?.aborted && performance.now() < deadline) {
    const view = await observer.sample();
    if (signal?.aborted) return "observation_stopped";
    if (performance.now() >= deadline) return "observation_timed_out";
    const output = JSON.stringify(view);
    if (output !== lastOutput) {
      emit(view);
      lastOutput = output;
    }
    if (view.status === "disconnected" || view.status === "connection_changed") return view.status;
    const remaining = deadline - performance.now();
    if (remaining <= 0) break;
    try { await delay(Math.min(2000, remaining), undefined, { signal }); }
    catch { if (!signal?.aborted) throw new Error("observation_failed"); }
  }
  return signal?.aborted ? "observation_stopped" : "observation_timed_out";
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  try {
    const [directory, streamID, duration = "600", ...rest] = process.argv.slice(2);
    if (rest.length || !directory || !/^[1-9]\d{0,3}$/.test(duration)) throw new Error();
    const status = await observeStream(directory, streamID, Number(duration), {
      signal: controller.signal,
      emit: view => process.stdout.write(`${JSON.stringify(view)}\n`),
    });
    process.stdout.write(`${JSON.stringify(empty(status))}\n`);
  } catch {
    process.stdout.write(`${JSON.stringify(empty("probe_unavailable"))}\n`);
    process.exitCode = 1;
  } finally {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
  }
}
