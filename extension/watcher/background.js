// Helm page watcher: the service worker half. Periodically reads each watched
// page (in its open tab if there is one, else in one minimized window) and
// records what changed.
// Needs watcher/shared.js loaded first.

const WATCHER_ALARM = "watcher-check";
const WATCHER_LOGIN_MARKERS = ["login", "signin", "sign-in", "authwall", "accounts.google.com", "idmsa.apple.com", "/ap/signin"];
const WATCHER_LOAD_TIMEOUT = 45000;

let watcherRunning = false;

const watcherSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// MARK: Scheduling

async function watcherSchedule() {
  const { minutes } = await watcherLoadState();
  await chrome.alarms.clear(WATCHER_ALARM);
  await chrome.alarms.create(WATCHER_ALARM, { delayInMinutes: 1, periodInMinutes: minutes });
}

async function watcherStartup() {
  await chrome.storage.local.set({ [WATCHER_KEY.checkingSince]: 0 });
  await watcherSchedule();
  await watcherUpdateBadge();
  watcherSendToBoard();
}

chrome.runtime.onInstalled.addListener(watcherStartup);
chrome.runtime.onStartup.addListener(watcherStartup);
// If the alarm has gone missing, checks would silently stop; put it back.
chrome.alarms.get(WATCHER_ALARM).then((alarm) => { if (!alarm) watcherSchedule(); });

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === WATCHER_ALARM) watcherRunChecks();
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes[WATCHER_KEY.minutes]) watcherSchedule();
  if (changes[WATCHER_KEY.watches]) {
    watcherUpdateBadge();
    watcherSendToBoard();
  }
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "watcher:checkNow") watcherRunChecks();
  if (message?.type === "watcher:checkTab") watcherCheckInTab(message.id, message.tabId);
  if (message?.type === "watcher:testPhone") {
    watcherLoadState().then(({ ntfy }) =>
      watcherPushToPhone(ntfy, "Helm", "Phone alerts are working.", ""));
  }
});

chrome.notifications.onClicked.addListener(async (id) => {
  if (!id.startsWith("watcher:")) return;
  const watchId = id.slice("watcher:".length);
  const { watches } = await watcherLoadState();
  const w = watches.find((x) => x.id === watchId);
  chrome.notifications.clear(id);
  if (!w) return;
  chrome.tabs.create({ url: w.url });
  w.unseen = false;
  await chrome.storage.local.set({ [WATCHER_KEY.watches]: watches });
});

// MARK: Badge

async function watcherUpdateBadge() {
  const { watches } = await watcherLoadState();
  const attention = watches.filter(watcherNeedsAttention).length;
  const remaining = watches.filter((w) => w.status !== "done").length;
  if (attention) {
    await chrome.action.setBadgeText({ text: String(attention) });
    await chrome.action.setBadgeBackgroundColor({ color: "#1a7f37" });
  } else {
    await chrome.action.setBadgeText({ text: remaining ? String(remaining) : "" });
    await chrome.action.setBadgeBackgroundColor({ color: "#9a6700" });
  }
  await chrome.action.setBadgeTextColor?.({ color: "#ffffff" });
}

// MARK: Helm's screensaver board

const WATCHER_NATIVE_HOST = "com.jonathanvineet.helm";
let watcherBoardTimer = null;

/** Hands the watch list to Helm.app (via native messaging) for the screensaver board. */
function watcherSendToBoard() {
  clearTimeout(watcherBoardTimer);
  watcherBoardTimer = setTimeout(async () => {
    const { watches } = await watcherLoadState();
    try {
      await chrome.runtime.sendNativeMessage(WATCHER_NATIVE_HOST, {
        type: "watcher:board",
        source: await watcherSource(),
        watches: watches.map(watcherBoardEntry),
      });
    } catch {
      // Helm.app isn't installed on this Mac; the popup and badge still work.
    }
  }, 300);
}

/**
 * Identifies this browser profile to Helm, so watches from several profiles
 * (each with its own copy of the extension) are shown together, not overwritten.
 */
async function watcherSource() {
  const { watcher_source } = await chrome.storage.local.get("watcher_source");
  if (watcher_source) return watcher_source;
  const source = crypto.randomUUID();
  await chrome.storage.local.set({ watcher_source: source });
  return source;
}

/** What the board shows for a watch. */
function watcherBoardEntry(w) {
  let state = "watching";
  const tone = w.insight?.tone;
  if (w.error || w.status === "login" || tone === "problem" || tone === "action") state = "attention";
  else if (w.status === "done") state = "done";
  else if (watcherNeedsAttention(w)) state = "attention";
  else if (w.status === "pending" || tone === "waiting") state = "pending";

  const insight = w.insight;
  let text, quoted = false;
  if (w.error) text = WATCHER_LABEL.error;
  else if (w.status === "login") text = WATCHER_LABEL.login;
  else if (insight?.stage) text = watcherInsightLine(insight);
  else if (w.mode === "keyword") text = WATCHER_LABEL[w.status] || "Not checked yet";
  else [text, quoted] = [w.current ?? "", true];

  return {
    name: w.name, text, quoted, state, since: w.since || 0, checked: w.checked || 0,
    kind: w.kind || "general", step: insight?.step || 0, steps: insight?.steps || 0,
  };
}

// MARK: Check run

async function watcherRunChecks() {
  if (watcherRunning) return;
  const { watches } = await watcherLoadState();
  if (!watches.length) return;

  watcherRunning = true;
  await chrome.storage.local.set({ [WATCHER_KEY.checkingSince]: Date.now() });
  // Chrome stops an idle service worker after 30 s; a check run takes longer.
  const keepAlive = setInterval(() => chrome.runtime.getPlatformInfo(), 20000);
  const results = new Map();
  let win;
  try {
    const openTabs = await chrome.tabs.query({});
    const focused = await chrome.windows.getLastFocused().catch(() => null);
    for (const w of watches) {
      try {
        const open = openTabs.find((t) => watcherSameUrl(t.url, w.url));
        if (open) {
          // The page is already open: check it there. Reload it for fresh
          // content, unless it's the tab you're looking at right now.
          const inUse = open.active && focused?.focused && open.windowId === focused.id;
          results.set(w.id, await watcherCheck(open.id, w, { navigate: false, reload: !inUse }));
        } else {
          // Not open anywhere: load it in one shared minimized window.
          if (!win) {
            win = await chrome.windows.create({ url: "about:blank", focused: false, state: "minimized" });
            await chrome.tabs.update(win.tabs[0].id, { muted: true });
          }
          results.set(w.id, await watcherCheck(win.tabs[0].id, w));
        }
      } catch (e) {
        results.set(w.id, { status: "error", detail: String(e?.message || e).slice(0, 120) });
      }
    }
  } catch (e) {
    for (const w of watches) {
      if (!results.has(w.id)) results.set(w.id, { status: "error", detail: String(e?.message || e).slice(0, 120) });
    }
  } finally {
    clearInterval(keepAlive);
    if (win) await chrome.windows.remove(win.id).catch(() => {});
    try {
      await watcherSaveResults(results, { lastRun: true });
    } finally {
      watcherRunning = false;
    }
  }
}

/** Applies check results to the watches as they are now in storage, so watches
 * added or removed meanwhile are respected. */
async function watcherSaveResults(results, { lastRun }) {
  const state = await watcherLoadState();
  const now = Date.now();
  for (const w of state.watches) {
    const result = results.get(w.id);
    if (result) watcherApply(w, result, now, state);
  }
  const update = { [WATCHER_KEY.watches]: state.watches };
  if (lastRun) Object.assign(update, { [WATCHER_KEY.checkingSince]: 0, [WATCHER_KEY.lastRun]: now });
  await chrome.storage.local.set(update);
}

/** First check of a new watch: read the tab it was added from, as it is, instead
 * of loading the page again in a minimized window. */
async function watcherCheckInTab(id, tabId) {
  const { watches } = await watcherLoadState();
  const w = watches.find((x) => x.id === id);
  if (!w || !tabId) return;
  let result;
  try {
    result = await watcherCheck(tabId, w, { navigate: false });
  } catch (e) {
    result = { status: "error", detail: String(e?.message || e).slice(0, 120) };
  }
  await watcherSaveResults(new Map([[id, result]]), { lastRun: false });
}

/** Loads a watch's page (unless it's already open in `tabId`) and reads it.
 * Returns a result; doesn't modify `w`. */
async function watcherCheck(tabId, w, { navigate = true, reload = false } = {}) {
  if (navigate) await watcherLoadPage(tabId, w.wait ?? 8, () => chrome.tabs.update(tabId, { url: w.url }));
  else if (reload) await watcherLoadPage(tabId, w.wait ?? 8, () => chrome.tabs.reload(tabId));
  const tab = await chrome.tabs.get(tabId);
  const url = (tab.url || "").toLowerCase();
  if (WATCHER_LOGIN_MARKERS.some((m) => url.includes(m))) return { status: "login" };

  if (w.mode === "keyword") {
    const body = await watcherRun(tabId, () => (document.body ? document.body.innerText : ""));
    return watcherClassify(body || "", w);
  }

  let text = await watcherRun(tabId, watcherReadSelector, [w.selector]);
  if (text === null) {
    await watcherSleep(5000);
    text = await watcherRun(tabId, watcherReadSelector, [w.selector]);
  }
  return { status: "read", text: text === null ? "(no longer on the page)" : watcherNormalize(text) };
}

/** Same page, ignoring the #fragment and a trailing slash. */
function watcherSameUrl(a, b) {
  const clean = (u) => String(u || "").split("#")[0].replace(/\/$/, "");
  return !!a && clean(a) === clean(b);
}

/** Navigates (or reloads) the tab and resolves once it has loaded and had `wait` seconds to render. */
async function watcherLoadPage(tabId, wait, start) {
  await new Promise((resolve, reject) => {
    let finished = false;
    const finish = (error) => {
      if (finished) return;
      finished = true;
      chrome.tabs.onUpdated.removeListener(listener);
      clearTimeout(timer);
      error ? reject(error) : resolve();
    };
    // Registered before navigating, so a fast load can't be missed.
    const listener = (id, info, tab) => {
      if (id === tabId && info.status === "complete" && tab.url !== "about:blank") finish();
    };
    chrome.tabs.onUpdated.addListener(listener);
    const timer = setTimeout(() => finish(), WATCHER_LOAD_TIMEOUT);
    start().catch(finish);
  });
  // Single-page apps render after the load event.
  await watcherSleep(Math.min(60, Math.max(2, Number(wait) || 8)) * 1000);
}

async function watcherRun(tabId, func, args = []) {
  const [injection] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return injection?.result ?? null;
}

/** Runs in the page. */
function watcherReadSelector(selector) {
  try {
    const el = document.querySelector(selector);
    return el ? (el.innerText || el.textContent || "") : null;
  } catch {
    return null;
  }
}

function watcherClassify(body, w) {
  let scope = body;
  if (w.anchor) {
    const at = body.toLowerCase().indexOf(w.anchor.toLowerCase());
    if (at < 0) return { status: "missing", hash: watcherHash("") };
    scope = body.slice(at, at + 500);
  }
  scope = scope.replace(/\s+/g, " ").trim();
  const low = scope.toLowerCase();
  const has = (phrases) => (phrases || []).some((p) => p && low.includes(p.toLowerCase()));
  const status = has(w.pending) ? "pending" : has(w.done) ? "done" : "changed";
  // With a heading to look under, the text there can be read for what it means.
  const insight = w.anchor ? watcherInterpret(w.kind, scope.slice(0, 500)) : null;
  return { status, hash: watcherHash(scope), insight };
}

/** djb2 */
function watcherHash(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

// MARK: Applying results

function watcherApply(w, result, now, settings) {
  w.checked = now;
  if (result.status === "error") {
    w.error = result.detail;
    return;
  }
  delete w.error;

  if (result.status === "login") {
    if (w.status !== "login") {
      w.beforeLogin = w.status;
      w.status = "login";
      watcherNotify(w, WATCHER_LABEL.login, settings);
    }
    return;
  }
  // Watches from before Helm understood pages get their kind worked out now.
  if (!w.kind) w.kind = watcherRecognize({ url: w.url, title: w.name, text: result.text ?? (w.pending || []).join(" ") }).kind;

  // Coming back from being signed out, compare against the status before it.
  const previous = w.status === "login" ? w.beforeLogin : w.status;
  delete w.beforeLogin;

  if (w.mode === "keyword") {
    const first = w.hash === undefined;
    if (!first && previous !== result.status) {
      watcherNotify(w, `${WATCHER_LABEL[previous] || "Unknown"} → ${WATCHER_LABEL[result.status]}`, settings);
      w.unseen = true;
    } else if (!first && result.status === "changed" && w.hash !== result.hash) {
      watcherNotify(w, "The page changed again", settings);
      w.unseen = true;
    }
    if (first || previous !== result.status) w.since = now;
    w.status = result.status;
    w.hash = result.hash;
    if (result.insight) w.insight = result.insight;
    return;
  }

  // Read the text as the kind of thing it is, and only speak up when what it
  // means changed: a new stage, an outcome, a new date, price or position.
  const insight = watcherInterpret(w.kind, result.text);
  const signature = watcherSignature(insight, result.text);
  if (result.text !== w.current) {
    const before = w.insight || watcherInterpret(w.kind, w.current);
    const beforeSignature = w.signature ?? watcherSignature(before, w.current);
    if (signature !== beforeSignature) {
      watcherNotify(w, watcherDescribeChange(before, insight, w.current, result.text), settings);
      w.unseen = true;
      w.since = now;
    }
    w.current = result.text;
  }
  w.insight = insight;
  w.signature = signature;
  w.status = watcherIsDone(w.current, w.done) || insight.tone === "done" ? "done" : "watching";
}

function watcherClip(text) {
  text = String(text ?? "");
  return text.length > 80 ? text.slice(0, 80) + "…" : text;
}

// MARK: Alerts

function watcherNotify(w, message, { alerts, ntfy }) {
  if (alerts !== "off") {
    chrome.notifications.create(`watcher:${w.id}`, {
      type: "basic",
      iconUrl: chrome.runtime.getURL("icon128.png"),
      title: w.name,
      message,
      silent: alerts === "quiet",
      requireInteraction: alerts === "sticky",
    });
  }
  watcherPushToPhone(ntfy, w.name, message, w.url);
}

/** JSON publishing, because ntfy's header form breaks on non-ASCII titles. */
async function watcherPushToPhone(topic, title, message, url) {
  if (!topic) return;
  const body = { topic, title, message, priority: 4 };
  if (url) body.click = url;
  try {
    await fetch("https://ntfy.sh/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    // Phone alerts are best effort.
  }
}
