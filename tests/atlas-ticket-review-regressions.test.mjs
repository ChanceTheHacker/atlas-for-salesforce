// Component sequences with Lightning/Apex stubbed; Apex tests cover the actual
// transaction, receipts and business writes. No org execution is claimed here.
import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import { LIMIT_REMINDER } from "../salesforce/force-app/main/default/lwc/atlasLib/protocol.js";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-ticket-review-"));
const outfile = join(dir, "conversation.mjs");
await build({
  entryPoints: [join(root, "atlasConversation/atlasConversation.js")], bundle: true, platform: "node", format: "esm", outfile,
  plugins: [{ name: "lightning-boundaries", setup(b) {
    b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
    b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
      path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};" :
      path.startsWith("@salesforce/apex/") ? `export default (args) => ${JSON.stringify(path.split(".").at(-1))} === "listWrites" ? Promise.resolve("[]") : globalThis.ticketReviewApex(${JSON.stringify(path.split(".").at(-1))}, args);` :
      path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"
    }));
    b.onResolve({ filter: /^c\/atlas/ }, ({ path }) => ({ path: join(root, path.slice(2), path.slice(2) + ".js") }));
    b.onLoad({ filter: /\/atlas[^/]+\/atlas[^/]+\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
  }}],
});
const Conversation = (await import(outfile)).default;
await rm(dir, { recursive: true });

const reviewed = () => ({ batch: { batchId: "stable", tickets: [{ ref: "T1", summary: "Exact proposal" }], expectedVersions: { "conversation:T1": "new" } } });
const pendingReview = () => { const review = reviewed(); return { ...review, batchJson: JSON.stringify(review.batch) }; };
const result = { saved: [{ ref: "T1", id: "ticket", atlasId: "TKT-1", issueType: "Task", summary: "Exact proposal" }], updates: [],
  receiptId: "receipt", acknowledgment: "Committed T1 → TKT-1; receipt receipt; update IDs are retained." };
function component() {
  const c = new Conversation();
  c.boot = { org: { id: "org" }, user: { id: "user" } };
  c.settings = { mine: { replyLimit: 100000 } };
  c.conversationId = "conversation";
  return c;
}
function browserStore() {
  const previous = globalThis.sessionStorage, values = new Map();
  globalThis.sessionStorage = { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: (key) => values.delete(key) };
  return () => { globalThis.sessionStorage = previous; };
}

test("ticket save displays the committed acknowledgment without a second message write", async () => {
  const c = component(), calls = [];
  c.ticketReview = reviewed(); c.load = async () => {};
  globalThis.ticketReviewApex = async (name) => {
    calls.push(name);
    if (name === "applyBatch") return JSON.stringify(result);
    throw Error("Separate handoff write is unavailable");
  };
  await c.saveTickets();
  assert.equal(c.problem, null);
  assert.equal(c.ticketReview, null);
  assert.equal(c.outgoing.original, result.acknowledgment);
  assert.equal(c.outgoing.parts[0].text, result.acknowledgment + "\n\n" + LIMIT_REMINDER);
  assert.equal(c.outgoing.state, "saved");
  assert.deepEqual(calls, ["applyBatch"]);
});

test("commit then response loss survives reload and explicitly retries the exact review", async () => {
  const restore = browserStore(), requests = [], acknowledgments = [];
  let state = {}, revision = 0, committed = false;
  globalThis.ticketReviewApex = async (name, args) => {
    if (name === "saveState") { state = JSON.parse(args.stateJson); return ++revision; }
    if (name === "getState") return JSON.stringify({ revision, data: state });
    if (name === "getConversation") return JSON.stringify({ id: "conversation", changes: [], tickets: [], messages: acknowledgments });
    assert.equal(name, "applyBatch");
    requests.push(args.batchJson);
    assert.deepEqual(state.ticketReview, pendingReview(), "The exact retry request is durable before submission");
    if (!committed) {
      committed = true;
      acknowledgments.push({ id: "message", direction: "To Agent", kind: "tickets", body: result.acknowledgment });
      throw Error("Response lost after commit");
    }
    return JSON.stringify(result);
  };
  try {
    const c = component(); c.draftLoaded = true; c.ticketReview = reviewed();
    await c.saveTickets();
    assert.match(c.problem.text, /lost/);
    assert.deepEqual(c.ticketReview, pendingReview());
    const reloaded = component(); await reloaded.load(true);
    assert.equal(requests.length, 1, "Reload must not automatically submit a review");
    assert.deepEqual(reloaded.ticketReview, pendingReview());
    assert.equal(reloaded.outgoing.original, result.acknowledgment);
    assert.equal(reloaded.outgoing.parts[0].text, result.acknowledgment + "\n\n" + LIMIT_REMINDER);
    assert.equal(reloaded.outgoing.state, "saved");
    assert.equal(reloaded.convo.messages[0].body, result.acknowledgment);
    await reloaded.saveTickets();
    assert.equal(reloaded.problem, null);
    assert.equal(reloaded.ticketReview, null);
    assert.equal(state.ticketReview, null);
    assert.equal(requests.length, 2);
    assert.equal(requests[0], requests[1]);
    assert.equal(acknowledgments.length, 1);
  } finally { restore(); }
});

// getState parses the saved JSON into Apex maps and serializes those maps again.
// Reversing every object's keys models a legal roundtrip without changing values.
function reordered(value) {
  if (Array.isArray(value)) return value.map(reordered);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).reverse().map(([key, item]) => [key, reordered(item)]));
  return value;
}

for (const explicitId of [false, true]) test(`committed response loss replays one ticket, receipt and handoff after reordered getState (${explicitId ? "explicit batchId" : "content identity"})`, async () => {
  const restore = browserStore(), requests = [], tickets = new Map(), receipts = new Map(), handoffs = [];
  let stateJson = "{}", revision = 0;
  const hash = (text) => createHash("sha256").update(text).digest("hex");
  globalThis.ticketReviewApex = async (name, args) => {
    if (name === "prepareBatch") return JSON.stringify({ ...JSON.parse(args.batchJson), expectedVersions: { "conversation:T1": "new" } });
    if (name === "saveState") {
      assert.equal(args.expectedRevision, revision);
      stateJson = args.stateJson;
      return ++revision;
    }
    if (name === "getState") return JSON.stringify({ revision, data: reordered(JSON.parse(stateJson)) });
    if (name === "getConversation") return JSON.stringify({ id: "conversation", changes: [], tickets: [...tickets.values()], messages: handoffs });
    assert.equal(name, "applyBatch");
    requests.push(args.batchJson);
    assert.equal(JSON.parse(stateJson).ticketReview.batchJson, args.batchJson, "The exact request must be durable before every apply");
    const batch = JSON.parse(args.batchJson), receiptInput = { ...batch };
    delete receiptInput.expectedVersions;
    // Model the order-sensitive receipt lookup and stale-version failure, not Apex DML.
    const digest = hash(JSON.stringify(receiptInput)), key = hash(batch.batchId ?? digest);
    const receipt = receipts.get(key);
    if (receipt) {
      if (receipt.digest !== digest) throw Error("This batchId already belongs to different content. Use a new batchId.");
      return receipt.response;
    }
    for (const t of batch.tickets) {
      if (tickets.has(t.ref) || batch.expectedVersions[`conversation:${t.ref}`] !== "new")
        throw Error("This ticket changed. Reload and review before applying; no changes in this chunk were saved.");
    }
    for (const t of batch.tickets) tickets.set(t.ref, { ...t, id: "ticket", revision: 1 });
    receipts.set(key, { digest, response: JSON.stringify(result) });
    handoffs.push({ id: "message", direction: "To Agent", kind: "tickets", body: result.acknowledgment });
    throw Error("Response lost after commit");
  };
  try {
    const c = component(); c.draftLoaded = true; c.boot.people = []; c.settings.jira = { projectKey: "DEMO" };
    await c.checkTickets({ type: "atlas-tickets", ...(explicitId ? { batchId: "stable" } : {}), tickets: [{
      ref: "T1", summary: "Exact proposal", description: "Keep the reviewed description", assignee: null,
      dueDate: "2026-10-20", dueDateSource: "input", customFields: { Team: "DEMO", Nullable: null },
    }] });
    const visible = structuredClone(c.ticketReview.items);
    await c.persistDraft();
    await c.saveTickets();
    assert.match(c.problem.text, /Response lost after commit/);
    assert.equal(tickets.size, 1); assert.equal(receipts.size, 1); assert.equal(handoffs.length, 1);
    const committed = structuredClone([...tickets.values()]);
    const reloaded = component(); await reloaded.load(true);
    assert.equal(reloaded.problem, undefined);
    assert.equal(requests.length, 1, "Hydration must not auto-submit");
    assert.deepEqual(reloaded.ticketReview.items, visible, "Reviewed content survives unchanged");
    assert.deepEqual(reloaded.ticketReview.batch, JSON.parse(requests[0]));
    assert.notEqual(JSON.stringify(reloaded.ticketReview.batch), requests[0], "The roundtrip must actually reorder the batch");
    assert.notDeepEqual(Object.keys(reloaded.ticketReview.batch.tickets[0].customFields), Object.keys(JSON.parse(requests[0]).tickets[0].customFields));
    assert.equal(reloaded.outgoing.original, result.acknowledgment);
    assert.equal(reloaded.outgoing.parts[0].text, result.acknowledgment + "\n\n" + LIMIT_REMINDER);
    assert.equal(reloaded.outgoing.state, "saved");
    assert.equal(reloaded.convo.messages[0].body, result.acknowledgment);
    await reloaded.saveTickets();
    assert.equal(reloaded.problem, null);
    assert.equal(reloaded.ticketReview, null);
    assert.equal(JSON.parse(stateJson).ticketReview, null);
    assert.equal(requests.length, 2);
    assert.equal(requests[1], requests[0], "Retry must replay the durable string byte-for-byte");
    assert.deepEqual([...tickets.values()], committed, "Receipt replay cannot rewrite the ticket");
    assert.equal(receipts.size, 1); assert.equal(handoffs.length, 1);
  } finally { restore(); }
});

test("failed recovery persistence stops before applying the ticket batch", async () => {
  const restore = browserStore(), c = component(), calls = [];
  c.draftLoaded = true; c.ticketReview = reviewed(); c.load = async () => {};
  globalThis.ticketReviewApex = async (name) => {
    calls.push(name);
    if (name === "saveState") throw Error("Draft storage unavailable");
    return JSON.stringify(result);
  };
  try {
    await c.saveTickets();
    assert.ok(calls.every((name) => name === "saveState"));
    assert.deepEqual(c.ticketReview, pendingReview());
    assert.match(c.problem.text, /storage unavailable/);
  } finally { restore(); }
});

test("missing committed acknowledgment retains the exact review for receipt replay", async () => {
  const c = component(); c.ticketReview = reviewed(); c.load = async () => {};
  globalThis.ticketReviewApex = async () => JSON.stringify({ saved: result.saved, updates: [] });
  await c.saveTickets();
  assert.deepEqual(c.ticketReview, pendingReview());
  assert.match(c.problem.text, /acknowledgment/i);
  assert.equal(c.outgoing, undefined);
});

test("Close and Reopen send only the status, so a long request is not stored again", async () => {
  const c = component(), sent = [];
  c.convo = { id: "conversation", title: "Long request", request: "x".repeat(5000), status: "Open" };
  c.load = async () => { c.convo = { ...c.convo, status: JSON.parse(sent.at(-1)).status }; };
  globalThis.ticketReviewApex = async (name, args) => {
    assert.equal(name, "saveConversation");
    sent.push(args.conversationJson);
    return "conversation";
  };
  await c.toggleClosed();
  await c.toggleClosed();
  assert.deepEqual(sent.map((json) => JSON.parse(json)), [{ id: "conversation", status: "Closed" }, { id: "conversation", status: "Open" }]);
});
