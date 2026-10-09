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
  if (w.insight && ["problem", "action"].includes(w.insight.tone)) return true;
  return w.mode === "keyword" && ["done", "changed", "missing"].includes(w.status);
}

/** "Out for delivery · Thursday", "Waitlisted · position 12", "₹1,499 · In stock". */
function watcherInsightLine(insight, { date = true } = {}) {
  const parts = [insight.stage];
  if (insight.kind === "product" && insight.price && insight.stage !== insight.price.text) parts.unshift(insight.price.text);
  if (date && insight.date && insight.tone !== "done") parts.push(insight.date);
  if (insight.position != null && insight.tone !== "done") parts.push(`position ${insight.position}`);
  return parts.filter(Boolean).join(" · ");
}

// MARK: How often to check

/**
 * Minutes until a watch should be checked again, given the interval set in
 * Settings. Close to the finish it's checked often; when nothing has moved for
 * days, less often; once finished, not at all (Check now still checks it).
 */
function watcherInterval(w, base, now = Date.now()) {
  if (w.status === "done") return Infinity;
  if (watcherNearlyThere(w, now)) return Math.min(base, 5);
  const quiet = now - (w.since || w.checked || now);
  if (quiet > 7 * 86400000) return Math.max(base, Math.min(360, base * 4));
  if (quiet > 3 * 86400000) return Math.max(base, Math.min(360, base * 2));
  return base;
}

/** One step from done (out for delivery, approved but not live), or due within hours. */
function watcherNearlyThere(w, now = Date.now()) {
  const i = w.insight;
  if (!i || i.tone !== "waiting") return false;
  if (i.steps > 2 && i.step === i.steps - 1) return true;
  return !!i.due && i.due - now < 6 * 3600000 && i.due - now > -12 * 3600000;
}

function watcherIsDue(w, base, now = Date.now()) {
  return !w.checked || now - w.checked >= watcherInterval(w, base, now) * 60000 - 30000;
}

/** Why a watch is checked more or less often than usual, for the popup; "" when it isn't. */
function watcherIntervalNote(w, base, now = Date.now()) {
  const minutes = watcherInterval(w, base, now);
  if (minutes === Infinity) return "finished, no longer checking";
  if (minutes < base) return `checking every ${minutes} min while it's this close`;
  if (minutes > base) {
    const every = minutes >= 60 ? `${minutes / 60} h` : `${minutes} min`;
    return `nothing's moved in a while, checking every ${every}`;
  }
  return "";
}
