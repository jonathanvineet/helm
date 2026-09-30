// End-to-end tests for Helm's page watcher: loads the unpacked extension into
// Chromium and points watches at a local fixture page.
import { test, expect, chromium } from "@playwright/test";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionPath = path.resolve(here, "../../extension");
const fixture = fs.readFileSync(path.join(here, "fixture.html"), "utf8");

/** What the fixture shows when there's no ?s=; tests change it between checks. */
let served = "Arriving Thursday";
let server, base, context, sw;

test.beforeAll(async () => {
  server = http.createServer((req, res) => {
    const { pathname } = new URL(req.url, "http://x");
    if (pathname === "/account") {
      res.writeHead(302, { Location: "/signin?next=account" }).end();
    } else if (pathname === "/signin") {
      res.writeHead(200, { "Content-Type": "text/html" }).end("<h1>Sign in</h1>");
    } else {
      res.writeHead(200, { "Content-Type": "text/html" }).end(fixture.replace("__DEFAULT__", served));
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "helm-watcher-"));
  context = await chromium.launchPersistentContext(profile, {
    channel: "chromium",
    args: [`--disable-extensions-except=${extensionPath}`, `--load-extension=${extensionPath}`],
  });
  sw = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker"));
});

test.afterAll(async () => {
  await context?.close();
  server?.close();
});

test.beforeEach(async () => {
  served = "Arriving Thursday";
  await sw.evaluate(() => chrome.storage.local.clear());
});

const setWatches = (watches) => sw.evaluate((w) => chrome.storage.local.set({ watcher_watches: w }), watches);
const runChecks = () => sw.evaluate(() => watcherRunChecks());
const getWatches = () => sw.evaluate(async () => (await watcherLoadState()).watches);
const badge = () => sw.evaluate(async () => ({
  text: await chrome.action.getBadgeText({}),
  color: await chrome.action.getBadgeBackgroundColor({}),
}));

function changeWatch(id, extra = {}) {
  return {
    id, name: id, url: `${base}/order`, mode: "change", done: ["Delivered"], wait: 2,
    selector: "#status", baseline: "Arriving Thursday", current: "Arriving Thursday",
    since: Date.now(), status: "watching", ...extra,
  };
}

test("selection inspector returns selectors that resolve to the selected element", async () => {
  const page = await context.newPage();
  await page.goto(`${base}/order`);
  const popup = await context.newPage();
  const extensionId = new URL(sw.url()).host;
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);

  const inspect = () => popup.evaluate(async (url) => {
    const tab = (await chrome.tabs.query({})).find((t) => t.url === url);
    const [injection] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: watcherInspectSelection });
    return injection.result;
  }, page.url());

  // Element with an id: the whole paragraph.
  await page.evaluate(() => {
    const range = document.createRange();
    range.selectNodeContents(document.getElementById("status"));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  });
  const byId = await inspect();
  expect(byId.selector).toBe("#status");
  expect(byId.elText).toBe("Arriving Thursday");
  expect(await page.evaluate((s) => document.querySelector(s) === document.getElementById("status"), byId.selector)).toBe(true);

  // Nested element without an id: part of a text node.
  await page.evaluate(() => {
    const text = document.querySelector("span").firstChild;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 7);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  });
  const nested = await inspect();
  expect(nested.text).toBe("Shipped");
  expect(nested.selector).toMatch(/^body > .*nth-of-type/);
  expect(await page.evaluate((s) => document.querySelector(s) === document.querySelector("span"), nested.selector)).toBe(true);
  expect(nested.elText).toBe("Shipped with Blue Dart");

  // Nothing selected.
  await page.evaluate(() => getSelection().removeAllRanges());
  expect(await inspect()).toBeNull();

  await popup.close();
  await page.close();
});

test("change mode detects a text change and marks it unseen", async () => {
  await setWatches([changeWatch("order")]);
  await runChecks();
  let [w] = await getWatches();
  expect(w.current).toBe("Arriving Thursday");
  expect(w.unseen).toBeFalsy();
  expect(w.status).toBe("watching");
  expect(w.checked).toBeGreaterThan(0);

  served = "Out for delivery";
  await runChecks();
  [w] = await getWatches();
  expect(w.current).toBe("Out for delivery");
  expect(w.unseen).toBe(true);
  expect(w.status).toBe("watching");

  served = "Delivered today";
  await runChecks();
  [w] = await getWatches();
  expect(w.current).toBe("Delivered today");
  expect(w.status).toBe("done");

  const state = await sw.evaluate(() => chrome.storage.local.get(null));
  expect(state.watcher_checkingSince).toBe(0);
  expect(state.watcher_lastRun).toBeGreaterThan(0);
});

test("change mode reports an element that disappeared", async () => {
  await setWatches([changeWatch("gone", { selector: "#nope" })]);
  await runChecks();
  const [w] = await getWatches();
  expect(w.current).toBe("(no longer on the page)");
  expect(w.unseen).toBe(true);
});

test("keyword mode goes from pending to changed when the waiting text disappears", async () => {
  served = "Review in progress";
  await setWatches([{
    id: "review", name: "Review", url: `${base}/app`, mode: "keyword", wait: 2,
    pending: ["Review in progress", "In review"], done: [], anchor: null,
  }]);
  await runChecks();
  let [w] = await getWatches();
  expect(w.status).toBe("pending");
  expect(w.since).toBeGreaterThan(0);
  expect(w.unseen).toBeFalsy();

  served = "Approved";
  await runChecks();
  [w] = await getWatches();
  expect(w.status).toBe("changed");
  expect(w.unseen).toBe(true);
});

test("login redirects are reported as signed out", async () => {
  await setWatches([changeWatch("account", { url: `${base}/account` })]);
  await runChecks();
  const [w] = await getWatches();
  expect(w.status).toBe("login");
});

test("removing a watch during a run doesn't bring it back", async () => {
  await setWatches([changeWatch("keep"), changeWatch("remove")]);
  await sw.evaluate(() => { self.testRun = watcherRunChecks(); });
  await new Promise((resolve) => setTimeout(resolve, 1000));
  await sw.evaluate(async () => {
    const { watcher_watches } = await chrome.storage.local.get("watcher_watches");
    await chrome.storage.local.set({ watcher_watches: watcher_watches.filter((w) => w.id !== "remove") });
  });
  await sw.evaluate(() => self.testRun);
  const watches = await getWatches();
  expect(watches.map((w) => w.id)).toEqual(["keep"]);
  expect(watches[0].checked).toBeGreaterThan(0);
});

test("badge follows the needs-attention rules", async () => {
  const green = [26, 127, 55, 255];
  const amber = [154, 103, 0, 255];
  const expectBadge = async (text, color) => {
    await expect.poll(badge).toEqual(color ? { text, color } : expect.objectContaining({ text }));
  };

  await setWatches([]);
  await expectBadge("");

  // Nothing needs attention: count the watches still going, in amber.
  await setWatches([changeWatch("a"), changeWatch("b"), changeWatch("c", { status: "done" })]);
  await expectBadge("2", amber);

  // Unseen, errors, signed out, and keyword done/changed/missing count, in green.
  await setWatches([
    changeWatch("unseen", { unseen: true }),
    changeWatch("error", { error: "boom" }),
    changeWatch("login", { status: "login" }),
    { ...changeWatch("kw-done"), mode: "keyword", status: "done" },
    { ...changeWatch("kw-changed"), mode: "keyword", status: "changed" },
    { ...changeWatch("kw-missing"), mode: "keyword", status: "missing" },
    { ...changeWatch("kw-pending"), mode: "keyword", status: "pending" },
    changeWatch("quiet"),
  ]);
  await expectBadge("6", green);
});

test("opening the popup marks updates as seen and shows them as new", async () => {
  await setWatches([changeWatch("order", { unseen: true, current: "Out for delivery" }), changeWatch("other")]);
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${new URL(sw.url()).host}/popup.html`);
  await expect(popup.locator("#watcher-list li")).toHaveCount(2);
  await expect(popup.locator("#watcher-list li.fresh .name")).toHaveText("order (new update)");
  await expect(popup.locator("#watcher-list li.fresh .status")).toHaveText("“Out for delivery”");
  await expect.poll(async () => (await getWatches()).some((w) => w.unseen)).toBe(false);

  // Stop watching removes it from storage and the list.
  await popup.getByRole("button", { name: "Stop watching other" }).click();
  await expect(popup.locator("#watcher-list li")).toHaveCount(1);
  expect((await getWatches()).map((w) => w.id)).toEqual(["order"]);
  await popup.close();
});

test("the form adds a keyword watch and checks it right away", async () => {
  served = "Changes in review";
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${new URL(sw.url()).host}/popup.html`);

  // Change mode needs a selection; the popup is its own active tab, so there is none.
  await popup.getByLabel("Name").fill("Play Console");
  await popup.getByLabel("Page address").fill(`${base}/console`);
  await popup.getByRole("button", { name: "Start watching" }).click();
  await expect(popup.locator("#watcher-error")).toContainText("Select the status text");

  await popup.getByLabel("some text disappears from the page").check();
  await expect(popup.getByLabel("Text shown while waiting")).toBeVisible();
  await popup.getByRole("button", { name: "Start watching" }).click();
  await expect(popup.locator("#watcher-error")).toContainText("text shown while you're waiting");

  await popup.getByLabel("Name").fill("Play Console");
  await popup.getByLabel("Page address").fill(`${base}/console`);
  await popup.getByLabel("Text shown while waiting").fill("Changes in review | In review");
  await popup.locator("summary", { hasText: "More options" }).click();
  await popup.getByLabel("Seconds to let the page load").fill("2");
  await popup.getByRole("button", { name: "Start watching" }).click();

  await expect(popup.locator("#watcher-list li .name")).toHaveText("Play Console");
  await expect.poll(async () => (await getWatches())[0]?.status, { timeout: 20000 }).toBe("pending");
  const [w] = await getWatches();
  expect(w.pending).toEqual(["Changes in review", "In review"]);
  expect(w.wait).toBe(2);
  await expect(popup.locator("#watcher-list li .status")).toHaveText("Still in review");
  await popup.close();
});

test("watch changes are sent to Helm.app for the screensaver board", async () => {
  await sw.evaluate(() => {
    self.sentToHelm = [];
    chrome.runtime.sendNativeMessage = async (host, message) => { self.sentToHelm.push({ host, message }); return { ok: true }; };
  });
  await setWatches([
    changeWatch("order", { unseen: true, current: "Out for delivery" }),
    { ...changeWatch("review"), mode: "keyword", status: "pending", since: 1000, checked: 2000 },
    changeWatch("signed-out", { status: "login" }),
    changeWatch("delivered", { status: "done", current: "Delivered" }),
  ]);
  await expect.poll(() => sw.evaluate(() => self.sentToHelm.length)).toBeGreaterThan(0);
  const { host, message } = await sw.evaluate(() => self.sentToHelm.at(-1));
  expect(host).toBe("com.jonathanvineet.helm");
  expect(message.type).toBe("watcher:board");
  expect(message.source).toMatch(/^[0-9a-f-]{36}$/);
  expect(message.watches).toEqual([
    expect.objectContaining({ name: "order", text: "Out for delivery", quoted: true, state: "attention" }),
    expect.objectContaining({ name: "review", text: "Still in review", quoted: false, state: "pending", since: 1000, checked: 2000 }),
    expect.objectContaining({ name: "signed-out", text: "Signed out, log in again", quoted: false, state: "attention" }),
    expect.objectContaining({ name: "delivered", text: "Delivered", quoted: true, state: "done" }),
  ]);
});

test("a new watch is first checked in the tab it was added from, without opening a window", async () => {
  served = "Review in progress";
  const page = await context.newPage();
  await page.goto(`${base}/review`);
  await setWatches([{
    id: "in-tab", name: "In tab", url: `${base}/review`, mode: "keyword", wait: 2,
    pending: ["Review in progress"], done: [], anchor: null,
  }]);
  const windowsBefore = await sw.evaluate(async () => (await chrome.windows.getAll()).length);
  let opened = 0;
  context.on("page", () => opened++);
  await sw.evaluate(async (url) => {
    const tab = (await chrome.tabs.query({})).find((t) => t.url === url);
    await watcherCheckInTab("in-tab", tab.id);
  }, page.url());
  const [w] = await getWatches();
  expect(w.status).toBe("pending");
  expect(w.checked).toBeGreaterThan(0);
  expect(opened).toBe(0);
  expect(await sw.evaluate(async () => (await chrome.windows.getAll()).length)).toBe(windowsBefore);
  await page.close();
});

test("a page that's already open is checked in its tab, not a new window", async () => {
  const page = await context.newPage();
  await page.goto(`${base}/order`);
  const other = await context.newPage();  // so the watched tab isn't the one in front
  await other.goto(`${base}/elsewhere`);
  await setWatches([changeWatch("open-tab", { url: page.url() })]);

  const windowsBefore = await sw.evaluate(async () => (await chrome.windows.getAll()).length);
  await sw.evaluate(() => {
    self.windowsCreated = 0;
    chrome.windows.onCreated.addListener(() => self.windowsCreated++);
  });

  served = "Out for delivery";
  await runChecks();
  const [w] = await getWatches();
  expect(w.current).toBe("Out for delivery");  // the open tab was reloaded
  expect(await sw.evaluate(() => self.windowsCreated)).toBe(0);
  expect(await sw.evaluate(async () => (await chrome.windows.getAll()).length)).toBe(windowsBefore);
  expect(await page.locator("#status").textContent()).toBe("Out for delivery");
  await other.close();
  await page.close();
});

test("understands a delivery: ignores timestamp churn, reports real stage changes", async () => {
  served = "In transit · updated 5 min ago";
  await sw.evaluate(() => {
    self.notified = [];
    const original = self.watcherNotify;
    self.watcherNotify = (w, message, settings) => { self.notified.push(message); original(w, message, settings); };
  });
  await setWatches([changeWatch("parcel", {
    kind: "delivery", current: "In transit · updated 5 min ago", baseline: "In transit · updated 5 min ago", done: [],
  })]);

  served = "In transit · updated 12 min ago";
  await runChecks();
  let [w] = await getWatches();
  expect(w.current).toBe("In transit · updated 12 min ago");
  expect(w.unseen).toBeFalsy();  // same stage, nothing to tell
  expect(w.insight).toMatchObject({ kind: "delivery", stage: "On the way", step: 3, steps: 5, tone: "waiting" });

  served = "Out for delivery";
  await runChecks();
  [w] = await getWatches();
  expect(w.unseen).toBe(true);
  expect(w.insight.stage).toBe("Out for delivery");

  served = "Delivered today";
  await runChecks();
  [w] = await getWatches();
  expect(w.status).toBe("done");  // no "done" phrase needed
  expect(await sw.evaluate(() => self.notified)).toEqual([
    "📦 Out for delivery (was On the way)",
    "📦 Delivered (was Out for delivery)",
  ]);
});

test("an older watch without a kind gets one on its next check", async () => {
  served = "Your changes are now in review.";
  await setWatches([changeWatch("legacy", {
    url: `${base}/console/publishing`, name: "Publishing overview", current: served, baseline: served, done: [],
  })]);
  await runChecks();
  const [w] = await getWatches();
  expect(w.kind).toBe("appReview");
  expect(w.insight.stage).toBe("In review");
});
