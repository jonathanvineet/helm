// Helm page watcher: the "Watching" section of the popup.
// Needs watcher/shared.js loaded first.

const $ = (id) => document.getElementById(id);

/** Watches that had unseen updates when the popup opened; shown in red while it stays open. */
const watcherFresh = new Set();
/** What was selected on the active tab when the popup opened, or null. */
let watcherSelection = null;

/** Injected into the active tab: describes the selected text and the element around it. */
function watcherInspectSelection() {
  const sel = getSelection();
  const text = sel ? sel.toString().replace(/\s+/g, " ").trim() : "";
  if (!text || !sel.rangeCount) return null;

  let el = sel.getRangeAt(0).commonAncestorContainer;
  if (el.nodeType === Node.TEXT_NODE) el = el.parentElement;
  if (!el || el.nodeType !== Node.ELEMENT_NODE) return null;

  const parts = [];
  let fromId = false;
  for (let node = el; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
    // Ids with long digit runs are usually generated per page load.
    if (node.id && !/\d{3,}/.test(node.id)) {
      const idSelector = "#" + CSS.escape(node.id);
      if (document.querySelectorAll(idSelector).length === 1) {
        parts.unshift(idSelector);
        fromId = true;
        break;
      }
    }
    let n = 1;
    for (let s = node.previousElementSibling; s; s = s.previousElementSibling) {
      if (s.tagName === node.tagName) n++;
    }
    parts.unshift(`${node.tagName.toLowerCase()}:nth-of-type(${n})`);
  }
  if (!fromId) parts.unshift("body");

  const elText = (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300);
  return { text, selector: parts.join(" > "), elText };
}

// MARK: Rendering

function watcherAgo(ts) {
  if (!ts) return "never";
  const min = Math.floor((Date.now() - ts) / 60000);
  if (min < 1) return "just now";
  if (min < 60) return `${min} min ago`;
  const h = Math.floor(min / 60);
  if (h <= 48) return `${h} h ago`;
  return `${Math.floor(h / 24)} days ago`;
}

function watcherStatusLine(w) {
  if (w.status === "login") return { text: WATCHER_LABEL.login, cls: "problem" };
  if (w.mode === "keyword") {
    const cls = { pending: "pending", done: "done", changed: "problem", missing: "problem" }[w.status] || "";
    return { text: WATCHER_LABEL[w.status] || "Not checked yet", cls };
  }
  return { text: `“${w.current ?? ""}”`, cls: w.status === "done" ? "done" : "" };
}

function watcherMetaLine(w) {
  const checked = w.checked ? `checked ${watcherAgo(w.checked)}` : "not checked yet";
  const lead = w.mode === "keyword"
    ? (w.since ? `In this state since ${watcherAgo(w.since)}` : "")
    : `Last changed ${watcherAgo(w.since)}`;
  return [lead, checked].filter(Boolean).join(", ").replace(/^./, (c) => c.toUpperCase());
}

function watcherRenderList(watches) {
  const list = $("watcher-list");
  list.replaceChildren();
  $("watcher-empty").hidden = watches.length > 0;

  for (const w of watches) {
    const fresh = watcherFresh.has(w.id);
    const li = document.createElement("li");
    if (fresh) li.className = "fresh";

    const top = document.createElement("div");
    top.className = "top";
    const name = document.createElement("a");
    name.className = "name";
    name.href = w.url;
    name.target = "_blank";
    name.rel = "noreferrer";
    name.textContent = w.name + (fresh ? " (new update)" : "");
    const stop = document.createElement("button");
    stop.type = "button";
    stop.className = "link";
    stop.textContent = "Stop watching";
    stop.setAttribute("aria-label", `Stop watching ${w.name}`);
    stop.addEventListener("click", () => watcherRemove(w.id));
    top.append(name, stop);

    const { text, cls } = watcherStatusLine(w);
    const status = document.createElement("div");
    status.className = `status ${cls}`;
    status.textContent = text;

    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = watcherMetaLine(w);
    li.append(top, status, meta);

    if (w.error) {
      const error = document.createElement("div");
      error.className = "meta problem";
      error.textContent = `${WATCHER_LABEL.error}: ${w.error}`;
      li.append(error);
    }
    list.append(li);
  }
}

function watcherRenderSettings(state) {
  const checking = state.checkingSince && Date.now() - state.checkingSince < 10 * 60000;
  const button = $("watcher-check-now");
  button.disabled = !!checking || !state.watches.length;
  button.textContent = checking ? "Checking…" : "Check now";

  $("watcher-minutes").value = String(state.minutes);
  watcherRenderNext(state, checking);
  for (const radio of document.querySelectorAll('input[name="alerts"]')) radio.checked = radio.value === state.alerts;
  const ntfy = $("watcher-ntfy");
  if (document.activeElement !== ntfy) ntfy.value = state.ntfy;
}

/** When the next automatic check is due, so it's clear checks are still happening. */
async function watcherRenderNext(state, checking) {
  const line = $("watcher-next");
  const alarm = await chrome.alarms.get("watcher-check");
  if (!state.watches.length || !alarm) {
    line.textContent = "";
  } else if (checking) {
    line.textContent = "Checking your pages now";
  } else {
    const min = Math.max(0, Math.round((alarm.scheduledTime - Date.now()) / 60000));
    line.textContent = `Next check ${min < 1 ? "in under a minute" : `in ${min} min`}` +
      (state.lastRun ? `, last one ${watcherAgo(state.lastRun)}` : "");
  }
}

async function watcherRender() {
  const state = await watcherLoadState();
  watcherRenderList(state.watches);
  watcherRenderSettings(state);
}

// MARK: The form

function watcherMode() {
  return document.querySelector('input[name="mode"]:checked').value;
}

function watcherRenderForm() {
  const keyword = watcherMode() === "keyword";
  $("watcher-pending-field").hidden = !keyword;
  $("watcher-anchor-field").hidden = !keyword;
  const preview = $("watcher-preview");
  preview.hidden = keyword;
  preview.textContent = watcherSelection
    ? `Watching: “${watcherSelection.elText}”`
    : "Nothing is selected. Close this popup, select the status text on the page, and open it again.";
}

function watcherPrefill(tab) {
  $("watcher-name").value = (tab?.title || "").slice(0, 40);
  $("watcher-url").value = /^https?:/.test(tab?.url || "") ? tab.url : "";
  $("watcher-pending").value = watcherSelection?.text || "";
  watcherRenderForm();
}

async function watcherSubmit(event, tab) {
  event.preventDefault();
  const error = $("watcher-error");
  error.textContent = "";
  const mode = watcherMode();
  const name = $("watcher-name").value.trim();
  const url = $("watcher-url").value.trim();
  const wait = Math.min(60, Math.max(2, Number($("watcher-wait").value) || 8));

  if (!name) return (error.textContent = "Give the watch a name.");
  if (!/^https?:\/\//.test(url)) return (error.textContent = "Enter a page address starting with http:// or https://.");

  const w = { id: crypto.randomUUID(), name, url, mode, done: watcherSplit($("watcher-done").value), wait };
  if (mode === "change") {
    if (!watcherSelection) return (error.textContent = "Select the status text on the page first, then open this popup again.");
    Object.assign(w, {
      selector: watcherSelection.selector,
      baseline: watcherSelection.elText,
      current: watcherSelection.elText,
      since: Date.now(),
      status: "watching",
    });
  } else {
    const pending = watcherSplit($("watcher-pending").value);
    if (!pending.length) return (error.textContent = "Enter the text shown while you're waiting.");
    w.pending = pending;
    w.anchor = $("watcher-anchor").value.trim() || null;
  }

  const { watches } = await watcherLoadState();
  watches.push(w);
  await chrome.storage.local.set({ [WATCHER_KEY.watches]: watches });
  $("watcher-form").reset();
  watcherPrefill(tab);
  // Check it straight away on the page that's already open, rather than
  // loading it again in a minimized window.
  if (tab?.id && tab.url === url) chrome.runtime.sendMessage({ type: "watcher:checkTab", id: w.id, tabId: tab.id });
  else chrome.runtime.sendMessage({ type: "watcher:checkNow" });
}

async function watcherRemove(id) {
  const { watches } = await watcherLoadState();
  await chrome.storage.local.set({ [WATCHER_KEY.watches]: watches.filter((w) => w.id !== id) });
}

// MARK: Opening the popup

async function watcherInit() {
  // Opening the popup counts as seeing every update: remember them for this
  // session, and clear them in storage (which clears the badge).
  const { watches } = await watcherLoadState();
  if (watches.some((w) => w.unseen)) {
    for (const w of watches) {
      if (w.unseen) watcherFresh.add(w.id);
      w.unseen = false;
    }
    await chrome.storage.local.set({ [WATCHER_KEY.watches]: watches });
  }

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab && /^https?:/.test(tab.url || "")) {
    try {
      const [injection] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: watcherInspectSelection });
      watcherSelection = injection?.result ?? null;
    } catch {
      // Browser-internal and store pages can't be scripted.
      watcherSelection = null;
    }
  }

  watcherPrefill(tab);
  for (const radio of document.querySelectorAll('input[name="mode"]')) radio.addEventListener("change", watcherRenderForm);
  $("watcher-form").addEventListener("submit", (e) => watcherSubmit(e, tab));
  $("watcher-check-now").addEventListener("click", () => chrome.runtime.sendMessage({ type: "watcher:checkNow" }));
  $("watcher-minutes").addEventListener("change", (e) =>
    chrome.storage.local.set({ [WATCHER_KEY.minutes]: Number(e.target.value) }));
  for (const radio of document.querySelectorAll('input[name="alerts"]')) {
    radio.addEventListener("change", (e) => chrome.storage.local.set({ [WATCHER_KEY.alerts]: e.target.value }));
  }
  $("watcher-ntfy").addEventListener("change", (e) =>
    chrome.storage.local.set({ [WATCHER_KEY.ntfy]: e.target.value.trim() }));
  $("watcher-test-phone").addEventListener("click", async () => {
    await chrome.storage.local.set({ [WATCHER_KEY.ntfy]: $("watcher-ntfy").value.trim() });
    chrome.runtime.sendMessage({ type: "watcher:testPhone" });
  });

  chrome.storage.onChanged.addListener((_, area) => { if (area === "local") watcherRender(); });
  await watcherRender();
}

watcherInit();
