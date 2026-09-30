// Helm page watcher: understanding what a watch is.
//
// Works out what kind of thing a watched page is (a delivery, an app review, a
// visa application…) and reads the watched text the way a person would: which
// step it's at, whether it finished or went wrong, and details like a delivery
// date, a price or a waitlist position. All on-device; no page text leaves the
// browser. Loaded by the service worker, the popup, and the unit tests.

/* A kind is recognised from hints in the address (sites and path words) and
 * from its stage wording in the text. Stages are in order; `problems` are
 * outcomes that need you (rejected, failed…); `actions` are "waiting on you". */
const WATCHER_KINDS = [
  {
    id: "delivery",
    label: "Delivery",
    icon: "📦",
    sites: ["amazon.", "flipkart.", "fedex.", "ups.com", "dhl.", "usps.", "bluedart", "delhivery", "indiapost",
      "aftership", "17track", "parcelsapp", "shiprocket", "ekart", "dtdc", "xpressbees", "meesho", "myntra",
      "ajio", "royalmail", "canadapost", "auspost", "ontrac", "lasership", "shopify", "track.", "tracking."],
    paths: ["track", "tracking", "shipment", "package", "order-details", "orderdetails", "your-orders", "progress-tracker", "/orders", "/order/"],
    stages: [
      { id: "ordered", label: "Ordered", match: [/\border(ed| placed| confirmed| received)\b/, /\bconfirmed\b/, /\bpayment (received|confirmed)\b/] },
      { id: "shipped", label: "Shipped", match: [/\bshipped\b/, /\bdispatched\b/, /\bpacked\b/, /\bhanded (over )?to (the )?(courier|carrier)\b/, /\blabel created\b/, /\bpicked up\b/] },
      { id: "transit", label: "On the way", match: [/\bin transit\b/, /\bwill be delivered\b/, /\b(delivery|arrival) (is )?(expected|estimated|scheduled)\b/, /\bscheduled for delivery\b/, /\bon (its|the) way\b/, /\barriv(ing|es)\b/, /\breached\b/, /\bat (the )?(hub|facility|sorting)\b/, /\bdeparted\b/, /\bexpected (delivery|by|on)\b/] },
      { id: "out", label: "Out for delivery", match: [/\bout for delivery\b/, /\bwith (the )?delivery (agent|driver|associate)\b/, /\barriving today\b/] },
      { id: "delivered", label: "Delivered", match: [/\bdelivered\b/, /\bpicked up by (you|customer)\b/, /\bhanded to (resident|customer|you)\b/] },
    ],
    problems: [
      { label: "Delivery attempt failed", match: [/\b(delivery )?attempt(ed)?\b.*\b(fail|unsuccessful|missed)/, /\b(fail|unsuccessful|missed)\w* (delivery )?attempt/, /\bundeliverable\b/, /\bdelivery (failed|exception)\b/] },
      { label: "Delayed", match: [/\bdelayed\b/, /\brunning late\b/, /\bdelivery exception\b/, /\bexception\b/] },
      { label: "Cancelled", match: [/\bcancell?ed\b/] },
      { label: "Being returned", match: [/\breturn(ed|ing)? to (sender|seller|origin)\b/, /\brto\b/] },
      { label: "Lost", match: [/\blost\b/, /\bdamaged\b/] },
    ],
  },
  {
    id: "appReview",
    label: "App review",
    icon: "📱",
    sites: ["play.google.com/console", "appstoreconnect.apple.com", "chrome.google.com/webstore/devconsole",
      "chromewebstore.google.com", "partner.microsoft.com", "developer.amazon.com/apps", "addons.mozilla.org/developers",
      "developer.huawei.com", "galaxystore.samsung.com"],
    paths: ["publishing", "app-review", "appstore", "submission", "release"],
    stages: [
      { id: "draft", label: "Not sent yet", match: [/\bnot (yet )?sent for review\b/, /\bprepare for submission\b/, /\bdraft\b/, /\bready to send\b/] },
      { id: "waiting", label: "Waiting for review", match: [/\bwaiting for review\b/, /\bsubmitted for review\b/, /\bsent for review\b/, /\bpending review\b/] },
      { id: "review", label: "In review", match: [/\bin review\b/, /\bunder review\b/, /\bbeing reviewed\b/, /\breview in progress\b/] },
      { id: "approved", label: "Approved", match: [/\bapproved\b/, /\bpending developer release\b/, /\bready to publish\b/, /\bprocessing for (the )?app store\b/] },
      { id: "live", label: "Live", match: [/\b(changes|update|app) (are |is )?(now )?(published|live)\b/, /\bready for (sale|distribution)\b/, /\bavailable on google play\b/, /\bpublished\b/, /\bis live\b/] },
    ],
    problems: [
      { label: "Rejected", match: [/\brejected\b/, /\bnot approved\b/, /\bpolicy (violation|issue)\b/, /\bguideline \d/] },
      { label: "Removed", match: [/\bremoved\b/, /\bsuspended\b/, /\bunpublished\b/, /\btaken down\b/] },
    ],
    actions: [{ label: "Action needed", match: [/\baction required\b/, /\bneeds? (your )?(attention|action)\b/, /\bresolve (these|the) issues\b/] }],
  },
  {
    id: "access",
    label: "Access request",
    icon: "🔑",
    sites: ["linkedin.com/developers", "developer.linkedin.com", "developers.facebook.com", "developer.x.com",
      "developer.twitter.com", "developers.tiktok.com", "platform.openai.com", "console.anthropic.com",
      "developer.apple.com", "developers.google.com", "cloud.google.com", "business.facebook.com"],
    paths: ["developers", "api", "access", "products", "waitlist", "beta", "early-access", "program"],
    stages: [
      { id: "requested", label: "Requested", match: [/\brequest(ed)?\b/, /\bsubmitted\b/, /\bapplied\b/, /\bon the waitlist\b/, /\bjoined the waitlist\b/] },
      { id: "review", label: "In review", match: [/\breview in progress\b/, /\bunder review\b/, /\bin review\b/, /\bpending( approval| review)?\b/, /\bprocessing\b/] },
      { id: "granted", label: "Access granted", match: [/\bapproved\b/, /\bgranted\b/, /\baccess (is )?(enabled|active)\b/, /\bactive\b/, /\benabled\b/, /\badded\b/, /\byou('re| are) in\b/] },
    ],
    problems: [{ label: "Declined", match: [/\bdenied\b/, /\brejected\b/, /\bdeclined\b/, /\bnot (been )?approved\b/, /\bineligible\b/, /\bunable to approve\b/] }],
    actions: [{ label: "More info needed", match: [/\b(more|additional) information (is )?(required|needed)\b/, /\baction required\b/, /\bcomplete (your|the) (application|profile|verification)\b/] }],
  },
  {
    id: "government",
    label: "Visa or government application",
    icon: "🛂",
    sites: ["vfsglobal", "travel.state.gov", "ceac.state.gov", "uscis.gov", "passportindia.gov.in", "gov.uk", "canada.ca",
      "immi.homeaffairs.gov.au", "blsinternational", "tlscontact", "gov.in", "gc.ca", "immigration", "visa", "passport",
      "incometax", "epfindia", "uidai", "parivahan"],
    paths: ["visa", "passport", "immigration", "case-status", "casestatus", "application-status", "track-application", "applicant"],
    stages: [
      { id: "submitted", label: "Submitted", match: [/\bsubmitted\b/, /\breceived\b/, /\bapplication (has been )?(filed|lodged)\b/, /\bbiometrics?\b/, /\bappointment\b/] },
      { id: "processing", label: "Processing", match: [/\bprocessing\b/, /\bunder (review|process|examination)\b/, /\bin (process|progress)\b/, /\badministrative processing\b/, /\bpending\b/] },
      { id: "decided", label: "Approved", match: [/\bapproved\b/, /\bissued\b/, /\bgranted\b/, /\bprinted\b/, /\bvisa (has been )?(issued|approved)\b/, /\bcase was approved\b/] },
      { id: "ready", label: "Ready or sent", match: [/\bready for (collection|pick ?up)\b/, /\bdispatched\b/, /\bdelivered\b/, /\bpassport (has been )?(sent|returned|dispatched)\b/, /\bcard (was )?(mailed|delivered)\b/] },
    ],
    problems: [{ label: "Refused", match: [/\brefused\b/, /\brejected\b/, /\bdenied\b/, /\bwithdrawn\b/, /\bcancell?ed\b/, /\bineligible\b/] }],
    actions: [{ label: "Documents needed", match: [/\brequest for evidence\b/, /\brfe\b/, /\b(additional|more) (documents?|information|evidence)\b/, /\baction required\b/, /\bbook (an |your )?appointment\b/, /\b221\s*\(?g\)?\b/] }],
  },
  {
    id: "job",
    label: "Job application",
    icon: "💼",
    sites: ["greenhouse.io", "lever.co", "myworkdayjobs", "workday", "linkedin.com/jobs", "naukri", "indeed.", "smartrecruiters",
      "ashbyhq", "wellfound", "angel.co", "instahyre", "hirist", "icims", "taleo", "successfactors", "jobvite", "careers"],
    paths: ["jobs", "careers", "candidate", "applications", "my-applications", "job-application"],
    stages: [
      { id: "applied", label: "Applied", match: [/\bapplied\b/, /\bapplication (submitted|received)\b/, /\bsubmitted\b/] },
      { id: "review", label: "In review", match: [/\bunder (review|consideration)\b/, /\bin review\b/, /\bscreening\b/, /\bbeing reviewed\b/, /\bviewed by (the )?(recruiter|employer)\b/] },
      { id: "interview", label: "Interviewing", match: [/\binterview\b/, /\bassessment\b/, /\bassignment\b/, /\bshortlisted\b/, /\bnext (round|step)\b/, /\bphone screen\b/] },
      { id: "offer", label: "Offer", match: [/\boffer\b/, /\bhired\b/, /\bselected\b/, /\bcongratulations\b/] },
    ],
    problems: [{ label: "Not selected", match: [/\bnot (to )?(moving|move|proceed)\w* (forward|further|ahead)\b/, /\bdecided not to (proceed|continue|pursue)\b/, /\bno longer (under consideration|being considered)\b/, /\bposition (has been )?filled\b/, /\brejected\b/, /\bunsuccessful\b/, /\bregret\b/, /\bnot selected\b/, /\bclosed\b/] }],
  },
  {
    id: "results",
    label: "Results or admission",
    icon: "🎓",
    sites: ["results", "nta.ac.in", "cbse", "ugc", "ielts", "ets.org", "collegeboard", "ucas.com", "commonapp", "admissions",
      "applyweb", "slate", "jee", "neet", "gate"],
    paths: ["result", "results", "admission", "admissions", "scorecard", "score"],
    stages: [
      { id: "waiting", label: "Not out yet", match: [/\b(not (yet )?(declared|published|released|available))\b/, /\b(coming|available) soon\b/, /\bto be (announced|declared|released)\b/, /\bawaited\b/, /\bunder review\b/, /\bsubmitted\b/] },
      { id: "waitlist", label: "Waitlisted", match: [/\bwait ?list(ed)?\b/, /\bdeferred\b/] },
      { id: "out", label: "Out", match: [/\b(declared|published|released|announced)\b/, /\b(result|score|scores)s? (is |are )?(now )?(out|available)\b/, /\badmitted\b/, /\baccepted\b/, /\bcongratulations\b/, /\bdecision (is )?(available|posted|released)\b/] },
    ],
    problems: [{ label: "Not admitted", match: [/\bnot (been )?(admitted|accepted|offered)\b/, /\bdenied\b/, /\brejected\b/, /\bunsuccessful\b/, /\bregret\b/] }],
  },
  {
    id: "booking",
    label: "Booking or waitlist",
    icon: "🎫",
    sites: ["irctc", "indianrail", "confirmtkt", "railyatri", "trainman", "pnr", "makemytrip", "cleartrip", "goibibo",
      "booking.com", "opentable", "resy", "redbus"],
    paths: ["pnr", "booking", "reservation", "waitlist", "itinerary"],
    stages: [
      { id: "waitlisted", label: "Waitlisted", match: [/\b(gn|pq|rl|tq|rs)?wl\b/, /\bwait ?list(ed)?\b/, /\bon hold\b/, /\brequested\b/] },
      { id: "rac", label: "RAC", match: [/\brac\b/, /\bpartially confirmed\b/] },
      { id: "confirmed", label: "Confirmed", match: [/\bcnf\b/, /\bconfirmed\b/, /\bbooked\b/, /\bchart prepared\b/, /\bseat (is )?allotted\b/] },
    ],
    problems: [{ label: "Cancelled", match: [/\bcancell?ed\b/, /\bcan\b(?=\s*\/)/, /\bfailed\b/, /\bexpired\b/, /\bnot confirmed\b/] }],
  },
  {
    id: "refund",
    label: "Refund, payment or claim",
    icon: "💸",
    sites: ["paypal.", "razorpay", "stripe.com", "paytm", "phonepe", "claims", "insurance", "incometax", "irs.gov", "refund"],
    paths: ["refund", "return", "claim", "payment", "payout", "reimbursement", "withdrawal"],
    stages: [
      { id: "requested", label: "Requested", match: [/\b(refund|return|claim|payment|withdrawal) (requested|initiated|raised|submitted|received)\b/, /\binitiated\b/, /\brequested\b/, /\bsubmitted\b/] },
      { id: "processing", label: "Processing", match: [/\bprocessing\b/, /\bin (process|progress)\b/, /\bunder review\b/, /\bpending\b/, /\bpick ?up scheduled\b/] },
      { id: "approved", label: "Approved", match: [/\bapproved\b/, /\bsanctioned\b/, /\baccepted\b/] },
      { id: "paid", label: "Paid", match: [/\brefunded\b/, /\bcredited\b/, /\bpaid\b/, /\bsettled\b/, /\b(refund|payment) (is |has been )?(completed|processed|issued)\b/, /\bdeposited\b/] },
    ],
    problems: [{ label: "Failed or declined", match: [/\bfailed\b/, /\bdeclined\b/, /\brejected\b/, /\breversed\b/, /\bdenied\b/, /\bon hold\b/] }],
    actions: [{ label: "Needs your input", match: [/\b(upload|provide|submit) (the )?(documents?|bank details|information)\b/, /\baction required\b/] }],
  },
  {
    id: "ticket",
    label: "Support ticket or issue",
    icon: "🎟️",
    sites: ["zendesk", "freshdesk", "atlassian.net", "jira", "linear.app", "servicenow", "helpscout", "intercom",
      "support.", "help.", "github.com", "gitlab.com"],
    paths: ["ticket", "tickets", "issues", "issue", "requests", "support", "case", "pull"],
    stages: [
      { id: "open", label: "Open", match: [/\bopen(ed)?\b/, /\bnew\b/, /\bsubmitted\b/, /\bcreated\b/] },
      { id: "working", label: "In progress", match: [/\bin progress\b/, /\bassigned\b/, /\binvestigating\b/, /\btriaged\b/, /\bworking on\b/, /\bescalated\b/, /\bin review\b/, /\breview required\b/] },
      { id: "resolved", label: "Resolved", match: [/\bresolved\b/, /\bclosed\b/, /\bfixed\b/, /\bmerged\b/, /\bdone\b/, /\bcompleted\b/, /\bsolved\b/] },
    ],
    problems: [{ label: "Declined", match: [/\bwon'?t (fix|do)\b/, /\bdeclined\b/, /\brejected\b/, /\bchanges requested\b/, /\bclosed (as|with) (not planned|unmerged)\b/] }],
    actions: [{ label: "Waiting on you", match: [/\b(awaiting|waiting (for|on)) (your|customer|requester) (reply|response|input)\b/, /\bpending (customer|requester|your)\b/, /\bneeds? (your )?(info|information|response)\b/] }],
  },
  {
    id: "build",
    label: "Build or deploy",
    icon: "🛠️",
    sites: ["github.com", "gitlab.com", "vercel.com", "netlify.", "circleci", "travis-ci", "bitbucket", "render.com",
      "railway.app", "fly.io", "heroku", "expo.dev", "codemagic", "bitrise", "buildkite", "app.netlify"],
    paths: ["actions", "runs", "pipelines", "pipeline", "deployments", "deploys", "builds", "build", "jobs"],
    stages: [
      { id: "queued", label: "Queued", match: [/\bqueued\b/, /\bwaiting\b/, /\bpending\b/, /\bscheduled\b/] },
      { id: "running", label: "Running", match: [/\brunning\b/, /\bin progress\b/, /\bbuilding\b/, /\bdeploying\b/, /\buploading\b/, /\bprocessing\b/] },
      { id: "done", label: "Succeeded", match: [/\bsucce(ss|eded|ssful)\b/, /\bpassed\b/, /\bdeployed\b/, /\bready\b/, /\bcompleted\b/, /\bpublished\b/, /\blive\b/] },
    ],
    problems: [{ label: "Failed", match: [/\bfail(ed|ure)?\b/, /\berror(ed)?\b/, /\bcancell?ed\b/, /\btimed out\b/, /\bcrashed\b/] }],
  },
  {
    id: "product",
    label: "Price or stock",
    icon: "🏷️",
    sites: ["amazon.", "flipkart.", "bestbuy", "walmart", "target.com", "apple.com/shop", "croma", "reliancedigital", "nykaa",
      "myntra", "ajio", "ebay.", "etsy", "aliexpress", "newegg"],
    paths: ["/dp/", "/p/", "/product", "/products/", "/item", "/buy", "/shop"],
    stages: [],
    problems: [],
  },
];

const WATCHER_GENERAL = {
  id: "general",
  label: "General",
  icon: "👀",
  sites: [],
  paths: [],
  stages: [
    { id: "waiting", label: "Waiting", match: [/\bpending\b/, /\bin (progress|review)\b/, /\bunder review\b/, /\bprocessing\b/, /\bwaiting\b/, /\bqueued\b/] },
    { id: "done", label: "Done", match: [/\bapproved\b/, /\baccepted\b/, /\bcompleted?\b/, /\bsucce(ss|eded|ssful)\b/, /\bresolved\b/, /\bdelivered\b/, /\bpublished\b/, /\bgranted\b/, /\bconfirmed\b/, /\bpassed\b/, /\bdone\b/, /\bready\b/] },
  ],
  problems: [{ label: "Problem", match: [/\brejected\b/, /\bfail(ed|ure)\b/, /\bdenied\b/, /\bdeclined\b/, /\bcancell?ed\b/, /\berror\b/, /\bsuspended\b/, /\bexpired\b/, /\brefused\b/] }],
  actions: [{ label: "Needs you", match: [/\baction required\b/, /\bneeds? your (attention|action|input)\b/] }],
};

const WATCHER_ALL_KINDS = [...WATCHER_KINDS, WATCHER_GENERAL];

function watcherKind(id) {
  return WATCHER_ALL_KINDS.find((k) => k.id === id) || WATCHER_GENERAL;
}

// MARK: Reading text

/** Words right before a match that turn it around ("not delivered", "yet to be shipped"). */
const WATCHER_NEGATION = /(\bnot|n't|\bno|\bnever|\byet to|\bto be|\bwill be|\bwould be|\bawaiting|\bpending|\bbefore|\bexpected to be|\bif|\bonce|\bwhen|\buntil)\s+(yet\s+|been\s+|be\s+|get\s+)?$/;

/** Whether `pattern` matches `text` in a way that isn't negated. */
function watcherSays(text, pattern) {
  const re = new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : pattern.flags + "g");
  for (const m of text.matchAll(re)) {
    const before = text.slice(Math.max(0, m.index - 24), m.index);
    if (!WATCHER_NEGATION.test(before)) return true;
  }
  return false;
}

function watcherSaysAny(text, patterns) {
  return (patterns || []).some((p) => watcherSays(text, p));
}

/** Timestamps and counters that change on their own and mean nothing. */
function watcherStripNoise(text) {
  return String(text ?? "")
    .toLowerCase()
    .replace(/\b(last )?(updated|refreshed|checked|synced|as of|fetched)\b[^.|\n]{0,40}/g, " ")
    .replace(/\b\d+\s*(s|sec|secs|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)\s+ago\b/g, " ")
    .replace(/\b(just now|moments? ago|a (few )?(seconds?|minutes?) ago)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const WATCHER_DAY = "(today|tonight|tomorrow|mon(day)?|tue(s(day)?)?|wed(nesday)?|thu(rs(day)?)?|fri(day)?|sat(urday)?|sun(day)?)";
const WATCHER_MONTH = "(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)";
const WATCHER_DATE = `(${WATCHER_DAY}(,?\\s+\\d{1,2}(st|nd|rd|th)?(\\s+${WATCHER_MONTH})?)?|\\d{1,2}(st|nd|rd|th)?\\s+${WATCHER_MONTH}|${WATCHER_MONTH}\\s+\\d{1,2}(st|nd|rd|th)?|\\d{1,2}[/-]\\d{1,2}([/-]\\d{2,4})?)`;

/** "Arriving Thursday", "expected by 3 Oct", "delivery by tomorrow 9 PM" → "Thursday", "3 Oct", "tomorrow". */
function watcherFindDate(text) {
  const re = new RegExp(`\\b(arriv(ing|es)|expected( delivery)?( on| by)?|estimated( delivery)?( date)?:?|deliver(y|s|ed)? (by|on)|due( on| by)?|by|on)\\s+${WATCHER_DATE}\\b`, "i");
  const m = String(text ?? "").match(re);
  if (!m) return null;
  const date = m[0].replace(/^\S+(\s+(delivery|on|by|date:?))*\s+/i, "");
  return date.charAt(0).toUpperCase() + date.slice(1);
}

/** "₹1,499", "$29.99", "Rs. 999", "EUR 45" → { text: "₹1,499", value: 1499 }. */
function watcherFindPrice(text) {
  const m = String(text ?? "").match(/(₹|\$|€|£|¥|rs\.?|inr|usd|eur|gbp)\s?(\d{1,3}(,\d{2,3})+|\d+)(\.\d{1,2})?/i);
  if (!m) return null;
  const value = Number((m[2] + (m[4] || "")).replace(/,/g, ""));
  return Number.isFinite(value) ? { text: m[0].replace(/\s+/g, " "), value } : null;
}

/** Waitlist and queue positions: "WL 23", "GNWL45/WL12", "position 7", "#3 in line". */
function watcherFindPosition(text) {
  const t = String(text ?? "");
  const wl = [...t.matchAll(/\b(?:gn|pq|rl|tq|rs)?wl\s*[/#-]?\s*(\d{1,4})\b/gi)];
  if (wl.length) return Number(wl[wl.length - 1][1]);  // current status comes after the booking status
  const m = t.match(/\b(?:position|place|number|no\.?|#)\s*(?:in (?:the )?(?:queue|line|waitlist)\s*)?[:#]?\s*(\d{1,6})\b/i)
    || t.match(/#\s*(\d{1,6})\s+(?:in|on) (?:the )?(?:queue|line|waitlist)/i);
  return m ? Number(m[1]) : null;
}

/** "Out of stock" / "In stock" / null when the text doesn't say. */
function watcherFindStock(text) {
  const t = String(text ?? "").toLowerCase();
  if (/\b(out of stock|sold out|currently unavailable|unavailable|notify me when available|not available)\b/.test(t)) return "out";
  if (/\b(in stock|add to (cart|bag|basket)|buy now|available now|only \d+ left)\b/.test(t)) return "in";
  return null;
}

// MARK: Recognising the kind

/**
 * Guesses what kind of thing a page is. The address counts most (a known site
 * or path), then the watched text's wording. Returns { kind, confidence 0–1 }.
 */
function watcherRecognize({ url = "", title = "", text = "" } = {}) {
  const address = String(url).toLowerCase();
  const words = `${title} ${text}`.toLowerCase();
  let best = { kind: "general", score: 0 };
  for (const kind of WATCHER_KINDS) {
    let score = 0;
    if (kind.sites.some((s) => address.includes(s))) score += 3;
    if (kind.paths.some((p) => address.includes(p))) score += 2;
    const phrases = [...kind.stages, ...(kind.problems || []), ...(kind.actions || [])].flatMap((s) => s.match);
    const hits = phrases.filter((p) => p.test(words)).length;
    score += Math.min(3, hits) * 1.2;
    // Kind-specific details are strong evidence.
    if (kind.id === "delivery" && watcherFindDate(words) && /\b(arriv|deliver|ship)/.test(words)) score += 2;
    if (kind.id === "booking" && /\b(pnr|(gn|pq|rl)?wl\s*\d|rac\s*\d|cnf)\b/.test(words)) score += 3;
    if (kind.id === "product") score = watcherFindPrice(words) || watcherFindStock(words) ? score + 2.5 : 0;
    if (score > best.score) best = { kind: kind.id, score };
  }
  if (best.score < 2) return { kind: "general", confidence: 0 };
  return { kind: best.kind, confidence: Math.min(1, best.score / 6) };
}

// MARK: Reading the status

/**
 * Reads watched text as `kindId`. Returns an insight:
 *   { kind, stage, step, steps, tone, date, price, position, stock }
 * tone: "waiting" (in progress), "done", "problem" (went wrong), "action"
 * (waiting on you), or "info" (couldn't tell).
 */
function watcherInterpret(kindId, text) {
  const kind = watcherKind(kindId);
  const t = String(text ?? "").toLowerCase().replace(/\s+/g, " ");
  const insight = { kind: kind.id, stage: null, step: 0, steps: kind.stages.length, tone: "info",
    date: watcherFindDate(text), price: null, position: null, stock: null };

  if (kind.id === "product") {
    insight.price = watcherFindPrice(t);
    insight.stock = watcherFindStock(t);
    insight.steps = 0;
    if (insight.stock === "out") [insight.stage, insight.tone] = ["Out of stock", "waiting"];
    else if (insight.stock === "in") [insight.stage, insight.tone] = ["In stock", "done"];
    else if (insight.price) [insight.stage, insight.tone] = [insight.price.text, "info"];
    return insight;
  }
  if (kind.id === "booking") insight.position = watcherFindPosition(t);

  const problem = (kind.problems || []).find((p) => watcherSaysAny(t, p.match));
  // Furthest stage the text says it has reached.
  let reached = -1;
  kind.stages.forEach((s, i) => { if (watcherSaysAny(t, s.match)) reached = i; });
  const action = (kind.actions || []).find((a) => watcherSaysAny(t, a.match));

  // A booking that's confirmed is still confirmed even though "WL" appears in its history.
  if (kind.id === "booking" && reached >= 0) {
    const current = t.split(/current status|\/|→|->/).pop();
    let now = -1;
    kind.stages.forEach((s, i) => { if (watcherSaysAny(current, s.match)) now = i; });
    if (now >= 0) reached = now;
  }

  if (reached >= 0) {
    insight.step = reached + 1;
    insight.stage = kind.stages[reached].label;
  }
  const last = kind.stages.length - 1;
  if (problem && reached !== last) {
    [insight.stage, insight.tone] = [problem.label, "problem"];
  } else if (action && reached !== last) {
    [insight.stage, insight.tone] = [action.label, "action"];
  } else if (reached === last) {
    insight.tone = "done";
  } else if (reached >= 0) {
    insight.tone = "waiting";
  }
  return insight;
}

/**
 * What must differ for a change to be worth telling you about: the stage,
 * the outcome, a new date, price, position or stock. For text the kind can't
 * read, the text itself (minus timestamps and counters).
 */
function watcherSignature(insight, text) {
  const parts = [insight.kind, insight.stage, insight.tone, insight.date, insight.price?.value, insight.position, insight.stock];
  if (!insight.stage && !insight.price && insight.position == null) parts.push(watcherStripNoise(text));
  return parts.map((p) => p ?? "").join("|");
}

/** A short line for a notification about a change from `before` to `after`. */
function watcherDescribeChange(before, after, oldText, newText) {
  const clip = (s) => (String(s).length > 80 ? String(s).slice(0, 80) + "…" : String(s));
  const kind = watcherKind(after.kind);
  if (after.kind === "product") {
    if (before?.stock === "out" && after.stock === "in") return `Back in stock${after.price ? ` at ${after.price.text}` : ""}`;
    if (before?.stock === "in" && after.stock === "out") return "Went out of stock";
    if (before?.price && after.price && before.price.value !== after.price.value) {
      const down = after.price.value < before.price.value;
      return `Price ${down ? "dropped" : "went up"} from ${before.price.text} to ${after.price.text}`;
    }
  }
  if (before?.position != null && after.position != null && before.position !== after.position) {
    return after.position < before.position
      ? `Moved up: position ${before.position} → ${after.position}`
      : `Moved back: position ${before.position} → ${after.position}`;
  }
  if (after.stage && after.stage !== before?.stage) {
    const detail = after.date && after.tone !== "done" ? ` · ${after.date}` : "";
    const lead = after.tone === "problem" ? "Problem: " : after.tone === "action" ? "Needs you: " : "";
    return `${kind.icon} ${lead}${after.stage}${detail}` + (before?.stage ? ` (was ${before.stage})` : "");
  }
  if (after.date && after.date !== before?.date) return `${kind.icon} Now ${after.date}${after.stage ? ` · ${after.stage}` : ""}`;
  return `“${clip(oldText)}” → “${clip(newText)}”`;
}

if (typeof module !== "undefined") {
  module.exports = {
    WATCHER_KINDS, watcherKind, watcherRecognize, watcherInterpret, watcherSignature, watcherDescribeChange,
    watcherFindDate, watcherFindPrice, watcherFindPosition, watcherFindStock, watcherStripNoise, watcherSays,
  };
}
