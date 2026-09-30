// Unit tests for the watcher's understanding layer (extension/watcher/understand.js).
// Run: node --test tests/extension/understand.test.cjs
const test = require("node:test");
const assert = require("node:assert/strict");
const u = require("../../extension/watcher/understand.js");

const read = (kind, text) => u.watcherInterpret(kind, text);
const recognize = (url, text, title = "") => u.watcherRecognize({ url, text, title }).kind;

test("recognizes kinds from the site, the path and the wording", () => {
  const cases = [
    ["https://www.amazon.in/gp/your-account/ship-track?orderId=1", "Arriving Thursday", "delivery"],
    ["https://www.fedex.com/fedextrack/?trknbr=1", "In transit", "delivery"],
    ["https://shop.example.com/orders/88", "Out for delivery", "delivery"],
    ["https://play.google.com/console/u/0/developers/1/app/2/publishing", "Your changes are now in review.", "appReview"],
    ["https://appstoreconnect.apple.com/apps/1/distribution", "Waiting for Review", "appReview"],
    ["https://www.linkedin.com/developers/apps/1/products", "Review in progress", "access"],
    ["https://ceac.state.gov/CEACStatTracker/Status.aspx", "Administrative Processing", "government"],
    ["https://egov.uscis.gov/casestatus/landing.do", "Case Was Received", "government"],
    ["https://boards.greenhouse.io/acme/applications/1", "Your application is under review", "job"],
    ["https://www.irctc.co.in/nget/pnr", "GNWL 45 / WL 12", "booking"],
    ["https://github.com/acme/app/actions/runs/1", "In progress", "build"],
    ["https://acme.zendesk.com/hc/requests/123", "Awaiting your reply", "ticket"],
    ["https://www.paypal.com/myaccount/transactions", "Refund initiated", "refund"],
    ["https://www.bestbuy.com/site/p/123", "Sold out $499.99", "product"],
    ["https://results.cbse.nic.in/", "Results will be declared soon", "results"],
    ["https://example.com/something", "hello world", "general"],
  ];
  for (const [url, text, kind] of cases) assert.equal(recognize(url, text), kind, `${url} "${text}"`);
});

test("recognizes kinds from wording alone on unknown sites", () => {
  assert.equal(recognize("https://tracker.example.org/x", "Your package is out for delivery, arriving today"), "delivery");
  assert.equal(recognize("https://example.org/x", "PNR 1234567890 GNWL 23 / WL 4"), "booking");
});

test("reads delivery stages, dates and problems", () => {
  const cases = [
    ["Order placed", "Ordered", "waiting", 1],
    ["Shipped. Arriving Thursday", "On the way", "waiting", 3],
    ["Arriving Thursday", "On the way", "waiting", 3],
    ["Out for delivery", "Out for delivery", "waiting", 4],
    ["Arriving today by 9 PM", "Out for delivery", "waiting", 4],
    ["Delivered today at 2:14 PM", "Delivered", "done", 5],
    ["Delivery attempt failed. We'll try again tomorrow", "Delivery attempt failed", "problem", 0],
    ["Shipment delayed. Now arriving Monday", "Delayed", "problem", 3],
    ["Your order has been cancelled", "Cancelled", "problem", 1],
  ];
  for (const [text, stage, tone] of cases) {
    const i = read("delivery", text);
    assert.equal(i.stage, stage, text);
    assert.equal(i.tone, tone, text);
  }
  assert.equal(read("delivery", "Arriving Thursday").date, "Thursday");
  assert.equal(read("delivery", "Expected delivery by 3 Oct").date, "3 Oct");
  assert.equal(read("delivery", "Out for delivery").steps, 5);
});

test("negations don't count", () => {
  assert.notEqual(read("delivery", "Not delivered yet. In transit").tone, "done");
  assert.equal(read("delivery", "Not delivered yet. In transit").stage, "On the way");
  assert.equal(read("delivery", "Will be delivered tomorrow").stage, "On the way");  // "delivered" is negated, "tomorrow" is a date
  assert.notEqual(read("appReview", "Your app has not been rejected").tone, "problem");
  assert.notEqual(read("general", "No errors found").tone, "problem");
});

test("reads app reviews", () => {
  assert.deepEqual(
    [read("appReview", "Your changes are now in review. We may find additional issues").stage, read("appReview", "Changes in review").tone],
    ["In review", "waiting"]);
  assert.equal(read("appReview", "Changes not yet sent for review").stage, "Not sent yet");
  assert.equal(read("appReview", "Waiting for Review").stage, "Waiting for review");
  assert.equal(read("appReview", "Ready for Sale").tone, "done");
  assert.equal(read("appReview", "Your changes are now published").tone, "done");
  assert.equal(read("appReview", "Rejected: Guideline 2.1").tone, "problem");
  assert.equal(read("appReview", "Action required: resolve these issues").tone, "action");
});

test("reads access requests, government, job and results pages", () => {
  assert.deepEqual([read("access", "Review in progress").stage, read("access", "Review in progress").tone], ["In review", "waiting"]);
  assert.equal(read("access", "Access granted").tone, "done");
  assert.equal(read("access", "Your request was denied").tone, "problem");
  assert.equal(read("government", "Administrative Processing").stage, "Processing");
  assert.equal(read("government", "Case Was Approved").stage, "Approved");
  assert.equal(read("government", "Passport dispatched via Speed Post").tone, "done");
  assert.equal(read("government", "Request for Evidence was sent").tone, "action");
  assert.equal(read("government", "Refused under section 221(g)").tone, "problem");
  assert.equal(read("job", "Interview scheduled").stage, "Interviewing");
  assert.equal(read("job", "We have decided not to move forward").tone, "problem");
  assert.equal(read("job", "Offer extended").tone, "done");
  assert.equal(read("results", "Result not yet declared").stage, "Not out yet");
  assert.equal(read("results", "Results declared").tone, "done");
  assert.equal(read("results", "You have been waitlisted").stage, "Waitlisted");
});

test("reads bookings and waitlist positions", () => {
  const wl = read("booking", "Booking status GNWL 45 / Current status WL 12");
  assert.equal(wl.stage, "Waitlisted");
  assert.equal(wl.position, 12);
  const cnf = read("booking", "Booking status WL 3 / Current status CNF B2 45");
  assert.equal(cnf.stage, "Confirmed");
  assert.equal(cnf.tone, "done");
  assert.equal(read("booking", "RAC 7").stage, "RAC");
  assert.equal(u.watcherFindPosition("You are #5 in the queue"), 5);
  assert.equal(u.watcherFindPosition("Position in waitlist: 213"), 213);
});

test("reads refunds, tickets and builds", () => {
  assert.equal(read("refund", "Refund initiated").stage, "Requested");
  assert.equal(read("refund", "Refund credited to your account").tone, "done");
  assert.equal(read("refund", "Payment failed").tone, "problem");
  assert.equal(read("ticket", "Awaiting your reply").tone, "action");
  assert.equal(read("ticket", "Resolved").tone, "done");
  assert.equal(read("ticket", "Merged").tone, "done");
  assert.equal(read("build", "In progress").stage, "Running");
  assert.equal(read("build", "Failed after 3m").tone, "problem");
  assert.equal(read("build", "Succeeded").tone, "done");
});

test("reads prices and stock", () => {
  assert.deepEqual(u.watcherFindPrice("Now ₹1,49,999 (was ₹1,59,999)"), { text: "₹1,49,999", value: 149999 });
  assert.deepEqual(u.watcherFindPrice("$29.99"), { text: "$29.99", value: 29.99 });
  assert.equal(read("product", "Currently unavailable").stock, "out");
  assert.equal(read("product", "In stock. Add to Cart ₹999").tone, "done");
});

test("ignores changes that don't matter", () => {
  const sig = (kind, text) => u.watcherSignature(read(kind, text), text);
  // Timestamps and counters.
  assert.equal(sig("general", "Status: waiting · updated 5 min ago"), sig("general", "Status: waiting · updated 12 min ago"));
  assert.equal(sig("general", "Queued, 3 minutes ago"), sig("general", "Queued, 9 minutes ago"));
  // Rewording within the same stage.
  assert.equal(sig("appReview", "Changes in review"), sig("appReview", "Your changes are now in review. We may find additional issues"));
  // Real changes.
  assert.notEqual(sig("delivery", "Arriving Thursday"), sig("delivery", "Arriving Friday"));
  assert.notEqual(sig("delivery", "In transit"), sig("delivery", "Out for delivery"));
  assert.notEqual(sig("product", "₹999 In stock"), sig("product", "₹899 In stock"));
  assert.notEqual(sig("booking", "WL 12"), sig("booking", "WL 8"));
});

test("describes changes like a person would", () => {
  const d = (kind, a, b) => u.watcherDescribeChange(read(kind, a), read(kind, b), a, b);
  assert.equal(d("delivery", "Arriving Thursday", "Out for delivery"), "📦 Out for delivery (was On the way)");
  assert.equal(d("delivery", "Out for delivery", "Delivered"), "📦 Delivered (was Out for delivery)");
  assert.equal(d("delivery", "Arriving Thursday", "Arriving Saturday"), "📦 Now Saturday · On the way");
  assert.equal(d("appReview", "In review", "Rejected"), "📱 Problem: Rejected (was In review)");
  assert.equal(d("product", "₹1,999 in stock", "₹1,499 in stock"), "Price dropped from ₹1,999 to ₹1,499");
  assert.equal(d("product", "Out of stock", "In stock ₹999"), "Back in stock at ₹999");
  assert.equal(d("booking", "GNWL 45 / WL 12", "GNWL 45 / WL 4"), "Moved up: position 12 → 4");
  assert.equal(d("general", "foo", "bar"), "“foo” → “bar”");
});
