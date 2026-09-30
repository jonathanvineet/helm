// Helm page watcher: definitions shared by the service worker and the popup.

const WATCHER_KEY = {
  watches: "watcher_watches",
  minutes: "watcher_minutes",
  alerts: "watcher_alerts",
  ntfy: "watcher_ntfy",
  checkingSince: "watcher_checkingSince",
  lastRun: "watcher_lastRun",
};

const WATCHER_LABEL = {
  pending: "Still in review",
  done: "Done",
  changed: "Page changed, go check",
  watching: "Watching for changes",
  login: "Signed out, log in again",
  missing: "Anchor text not found",
  error: "Check failed",
};

async function watcherLoadState() {
  const s = await chrome.storage.local.get(Object.values(WATCHER_KEY));
  return {
    watches: s[WATCHER_KEY.watches] || [],
    minutes: s[WATCHER_KEY.minutes] || 30,
    alerts: s[WATCHER_KEY.alerts] || "off",
    ntfy: s[WATCHER_KEY.ntfy] || "",
    checkingSince: s[WATCHER_KEY.checkingSince] || 0,
    lastRun: s[WATCHER_KEY.lastRun] || 0,
  };
}

function watcherNormalize(text) {
  return String(text ?? "").replace(/\s+/g, " ").trim().slice(0, 300);
}

/** "a | b|c" → ["a", "b", "c"] */
function watcherSplit(text) {
  return String(text ?? "").split("|").map((p) => p.trim()).filter(Boolean);
}

function watcherIsDone(text, done) {
  const low = String(text ?? "").toLowerCase();
  return (done || []).some((p) => p && low.includes(p.toLowerCase()));
}

/** Whether a watch should be counted on the badge and shown as an update. */
function watcherNeedsAttention(w) {
  if (w.unseen || w.error || w.status === "login") return true;
  return w.mode === "keyword" && ["done", "changed", "missing"].includes(w.status);
}
