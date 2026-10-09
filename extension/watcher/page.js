// Helm page watcher: code that runs inside watched pages. Injected (with
// understand.js) by the popup to describe a selection, and by the service
// worker to find a watched status again after the page was redesigned.

function watcherText(el) {
  return String(el?.innerText || el?.textContent || "").replace(/\s+/g, " ").trim();
}

/** A CSS path to `el`: from the nearest unique, stable id, else from body. */
function watcherCssPath(el) {
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
  return parts.join(" > ");
}

/**
 * The label that goes with `el`, like "Delivery status" or "Publishing
 * overview": short text just before it, or before one of its parents.
 * Remembered so the status can be found again if the page is rebuilt.
 */
function watcherContextOf(el) {
  const own = watcherText(el);
  for (let node = el, depth = 0; node && node !== document.body && depth < 6; node = node.parentElement, depth++) {
    let s = node.previousElementSibling;
    for (let n = 0; s && n < 4; s = s.previousElementSibling, n++) {
      const t = watcherText(s);
      if (t.length >= 3 && t.length <= 80 && t !== own) return t;
    }
  }
  return null;
}

/** Describes the current selection and the element around it, or null. */
function watcherInspectSelection() {
  const sel = getSelection();
  const text = sel ? sel.toString().replace(/\s+/g, " ").trim() : "";
  if (!text || !sel.rangeCount) return null;
  let el = sel.getRangeAt(0).commonAncestorContainer;
  if (el.nodeType === Node.TEXT_NODE) el = el.parentElement;
  if (!el || el.nodeType !== Node.ELEMENT_NODE) return null;
  return {
    text,
    selector: watcherCssPath(el),
    elText: watcherText(el).slice(0, 300),
    context: watcherContextOf(el),
    tag: el.tagName.toLowerCase(),
  };
}

/**
 * Finds a watched status whose selector stopped matching. Scores visible,
 * small elements by: the same text as last time, sitting near the remembered
 * label, reading as a stage of the watch's kind, similar wording, the same tag.
 * Returns { text, selector } only when fairly sure, else null.
 */
function watcherHeal({ lastText, context, kind, tag }) {
  const last = String(lastText || "").toLowerCase();
  const label = String(context || "").toLowerCase();
  const words = (s) => new Set(s.toLowerCase().match(/[\p{L}\p{N}₹$€£]+/gu) || []);
  const lastWords = words(last);
  const similarity = (t) => {
    const w = words(t);
    if (!w.size || !lastWords.size) return 0;
    let both = 0;
    for (const x of w) if (lastWords.has(x)) both++;
    return both / (w.size + lastWords.size - both);
  };
  const all = [...document.body.querySelectorAll("*")].slice(0, 6000);
  const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "SVG", "PATH", "TEMPLATE", "IFRAME"]);

  // Where the remembered label is now: the smallest element showing it.
  // Statuses usually come right after their label.
  let labelAt = -1;
  if (label) {
    let shortest = Infinity;
    all.forEach((el, i) => {
      if (skip.has(el.tagName)) return;
      const t = watcherText(el).toLowerCase();
      if (t.includes(label) && t.length < shortest) [shortest, labelAt] = [t.length, i];
    });
  }

  let best = null;
  for (const [i, el] of all.entries()) {
    if (skip.has(el.tagName) || el.children.length > 4 || !el.getClientRects().length) continue;
    const t = watcherText(el);
    const low = t.toLowerCase();
    if (t.length < 2 || t.length > 300 || (label && low === label)) continue;
    let score = 0;
    if (last && low === last) score += 100;
    score += similarity(t) * 40;
    if (labelAt >= 0 && i > labelAt && i - labelAt <= 20) score += 30 * (1 - (i - labelAt) / 20);
    if (kind && kind !== "general" && typeof watcherInterpret === "function" && watcherInterpret(kind, t).stage) score += 25;
    if (tag && el.tagName.toLowerCase() === tag) score += 5;
    score -= t.length / 100;  // prefer the tightest element
    if (!best || score > best.score || (score === best.score && best.el.contains(el))) best = { el, score, text: t };
  }
  if (!best || best.score < 40) return null;
  return { text: best.text, selector: watcherCssPath(best.el) };
}
