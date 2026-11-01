// Exercise component methods with platform/DOM boundaries stubbed. Real Lightning
// rendering, permissions and clipboard behavior are covered by the live org test.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-components-"));
const calls = [];
globalThis.atlasApexTest = async (name, args) => { calls.push({ name, args }); };
globalThis.atlasListWritesTest = null;
const components = {};
for (const name of ["atlas", "atlasChanges", "atlasConversation", "atlasCopy", "atlasTickets", "atlasWork", "atlasReview"]) {
  const outfile = join(dir, name + ".mjs");
  await build({
    entryPoints: [join(root, name, name + ".js")], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{ name: "lightning-boundaries", setup(b) {
      b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
      b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
        path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};" :
        path.startsWith("@salesforce/apex/") ? `export default (args) => ${JSON.stringify(path.split(".").at(-1))} === "listWrites" ? (globalThis.atlasListWritesTest ? globalThis.atlasListWritesTest(args) : Promise.resolve("[]")) : globalThis.atlasApexTest(${JSON.stringify(path.split(".").at(-1))}, args);` :
        path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"
      }));
      b.onResolve({ filter: /^c\/atlas/ }, ({path}) => ({ path: join(root, path.slice(2), path.slice(2) + ".js") }));
      b.onLoad({ filter: /\/atlas[^/]+\/atlas[^/]+\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
    }}],
  });
  components[name] = (await import(outfile)).default;
}
await rm(dir, { recursive: true });

test("returning to a retained Tickets or Changes panel reloads its list", () => {
  const host = new components.atlas();
  const reloads = [];
  const panels = { "c-atlas-tickets": { refresh: () => reloads.push("tickets") }, "c-atlas-changes": { refresh: () => reloads.push("changes") } };
  host.template = { querySelector: (selector) => panels[selector] || null };
  host.activeTab = "tickets"; host.activeTab = "changes";
  assert.deepEqual(reloads, [], "A first visit loads through the panel's own connectedCallback.");
  host.activeTab = "work"; host.activeTab = "tickets"; host.activeTab = "tickets"; host.activeTab = "changes";
  assert.deepEqual(reloads, ["tickets", "changes"], "Each return reloads once; staying on a panel does not.");
  host.activeTab = "library"; host.activeTab = "work"; host.activeTab = "library";
  assert.deepEqual(reloads, ["tickets", "changes"], "Other panels keep their own refresh controls.");
});

test("the Changes list reloads without closing the selected change", async () => {
  const changes = new components.atlasChanges();
  changes.selected = { id: "a0X1", status: "Proposed" };
  calls.length = 0;
  globalThis.atlasApexTest = async (name) => { calls.push({ name }); return JSON.stringify({ items: [{ id: "a0X2", requested: [] }], hasMore: false, nextCursor: null }); };
  await changes.refresh();
  assert.deepEqual(calls.map((c) => c.name), ["changePage"]);
  assert.deepEqual(changes.changes.map((c) => c.id), ["a0X2"]);
  assert.equal(changes.selected.id, "a0X1");
  globalThis.atlasApexTest = async (name, args) => { calls.push({ name, args }); };
});

test("Jira recovery routes to Tickets without replacing a queued Work request", () => {
  const host = new components.atlas();
  host.openRequest = { draft: { title: "Unsent conversation" } };
  const draft = { type: "atlas-jira-operation", version: 1, operation: "export" };
  host.handleOpenConversation({ detail: { draft } });
  assert.equal(host.activeTab, "tickets");
  assert.deepEqual(host.ticketRecovery, draft);
  assert.notEqual(host.ticketRecovery, draft);
  assert.equal(host.openRequest.draft.title, "Unsent conversation");
  host.handleOpenConversation({ detail: { draft: { title: "Recovered work" } } });
  assert.equal(host.activeTab, "work");
  assert.equal(host.openRequest.draft.title, "Recovered work");
  assert.equal(host.ticketRecovery.operation, "export");
});

test("bootstrap assembles all people pages before exposing a complete directory", async () => {
  const c = new components.atlas(), original = globalThis.atlasApexTest;
  const person = (id) => ({ id: String(id), name: `Person ${id}` });
  const cursors = [];
  let corrupt = false;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "bootstrap") return JSON.stringify({ people: [person(0)], peopleCursor: "1", settings: {} });
    assert.equal(name, "peoplePage"); cursors.push(args.afterId);
    const start = Number(args.afterId), end = Math.min(start + 200, 1201);
    return { people: Array.from({ length: end - start }, (_, i) => person(corrupt ? 0 : start + i)), nextCursor: end < 1201 ? String(end) : null };
  };
  try {
    await c.load(); assert.equal(c.boot.people.length, 1201); assert.equal(c.error, null); assert.equal(cursors.length, 6);
    const previous = c.boot;
    corrupt = true; await c.load(); assert.match(c.error, /repeated a record/); assert.equal(c.boot, previous);
  } finally { globalThis.atlasApexTest = original; }
});

test("a stale directory continuation cannot overwrite a newer bootstrap", async () => {
  const c = new components.atlas(), original = globalThis.atlasApexTest;
  let finish, loads = 0;
  globalThis.atlasApexTest = async (name) => {
    if (name === "bootstrap") return JSON.stringify({ people: [{ id: String(++loads), name: `Person ${loads}` }], peopleCursor: loads === 1 ? "cursor" : null, settings: {} });
    return new Promise((resolve) => { finish = resolve; });
  };
  try {
    const old = c.load(); await Promise.resolve(); await Promise.resolve();
    await c.load(); finish({ people: [], nextCursor: null }); await old;
    assert.equal(c.boot.people[0].id, "2"); assert.equal(c.error, null);
  } finally { globalThis.atlasApexTest = original; }
});

test("change history loads every page and preserves previous rows on invalid continuation", async () => {
  const c = new components.atlasChanges(), original = globalThis.atlasApexTest;
  let corrupt = false;
  globalThis.atlasApexTest = async (name, { beforeId }) => {
    assert.equal(name, "changePage");
    const offset = Number(beforeId || 205), end = Math.max(0, offset - 50);
    const items = Array.from({ length: offset - end }, (_, i) => ({ id: String(offset - i - 1) }));
    if (corrupt) items[0].id = c.changes[0].id;
    return JSON.stringify({ items, nextCursor: end ? String(end) : null, hasMore: end > 0 });
  };
  try {
    await c.load(); assert.equal(c.changes.length, 50);
    corrupt = true; await c.more(); assert.equal(c.changes.length, 50); assert.match(c.error, /Repeated/);
    corrupt = false;
    while (c.hasMore) await c.more();
    assert.equal(c.changes.length, 205); assert.equal(c.error, null);
    await c.more(); assert.equal(c.changes.length, 205);
  } finally { globalThis.atlasApexTest = original; }
});

test("late change-history pages and failures cannot replace a newer reload", async () => {
  const c = new components.atlasChanges(), original = globalThis.atlasApexTest;
  let finish, reject, requests = 0;
  globalThis.atlasApexTest = async () => {
    requests++;
    if (requests === 1) return new Promise((resolve) => { finish = resolve; });
    if (requests === 3) return new Promise((_, fail) => { reject = fail; });
    return JSON.stringify({ items: [{ id: "current" }], nextCursor: "current", hasMore: true });
  };
  try {
    const old = c.load(); await c.load();
    finish(JSON.stringify({ items: [{ id: "stale" }], nextCursor: null, hasMore: false })); await old;
    assert.equal(c.changes[0].id, "current");
    const pending = c.more(); await c.load(); reject(Error("Obsolete failure")); await pending;
    assert.equal(c.error, null); assert.equal(c.changes[0].id, "current");
  } finally { globalThis.atlasApexTest = original; }
});

test("closing a completed deployment during its final fetch cannot reopen it", async () => {
  const c = new components.atlasChanges(), original = globalThis.atlasApexTest;
  let finish;
  c.selected = { id: "change", status: "Deploying" };
  globalThis.atlasApexTest = async (name) => {
    if (name === "deployStatus") return JSON.stringify({ done: true, change: { name: "Test", status: "Deployed" } });
    assert.equal(name, "getChange");
    return new Promise((resolve) => { finish = resolve; });
  };
  try {
    const pending = c.watch();
    await Promise.resolve(); await Promise.resolve();
    c.close(); finish(JSON.stringify({ id: "change", status: "Deployed" })); await pending;
    assert.equal(c.selected, null);
  } finally { globalThis.atlasApexTest = original; }
});

test("Jira import reports stale rows instead of silently ignoring them", async () => {
  const component = new components.atlasTickets();
  component.settings = {};
  component.saveRecovery = async () => ({ id: "review", versionId: "review-version" });
  component.load = async () => {};
  const original = globalThis.atlasApexTest;
  globalThis.atlasApexTest = async () => JSON.stringify({ matchedByKey: 0, matchedDrafts: 0, created: 0, stale: 1 });
  try {
    await component.importFile({ target: { files: [{ text: async () => 'Issue key,Summary\nDEMO-1,Older\n' }] } });
    assert.ok(component.importing, "Import requires a review before mutation");
    await component.confirmImport();
    assert.match(component.message, /1 stale.*kept/i);
  } finally { globalThis.atlasApexTest = original; }
});

test("ticket board follows keyset pages beyond 3000 rows", async () => {
  const c = new components.atlasTickets();
  const original = globalThis.atlasApexTest;
  const cursors = [];
  globalThis.atlasApexTest = async (name, { afterId }) => {
    assert.equal(name, "boardPage"); cursors.push(afterId);
    const offset = Number(afterId || 0), end = Math.min(offset + 200, 3201);
    return { tickets: Array.from({ length: end - offset }, (_, i) => ({ id: String(offset + i) })), nextCursor: end < 3201 ? String(end) : null };
  };
  try { await c.load(); assert.equal(c.tickets.length, 3201); assert.equal(cursors.length, 17); }
  finally { globalThis.atlasApexTest = original; }
});

test("partial import failure retains receipts and resumes at the failed chunk", async () => {
  const c = new components.atlasTickets(); c.settings = {}; c.load = async () => {};
  c.saveRecovery = async () => ({ id: "review", versionId: "review-version" });
  const original = globalThis.atlasApexTest;
  let calls = 0, failed = true;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "beginImport") return "manifest";
    const chunk = JSON.parse(args.rowsJson).chunk;
    calls++;
    if (chunk === 1 && failed) return JSON.stringify({ applied: false, error: "Conflict", receiptId: "failed" });
    return JSON.stringify({ applied: true, created: chunk === 0 ? 50 : 1, receiptId: "ok" + chunk });
  };
  try {
    const csv = "Issue key,Summary\n" + Array.from({ length: 51 }, (_, i) => `DEMO-${i + 1},Ticket ${i}`).join("\n");
    await c.importFile({ target: { files: [{ text: async () => csv }] } });
    assert.equal(calls, 0);
    await c.confirmImport();
    assert.equal(c.importing.next, 50); assert.match(c.error, /stopped after 50/);
    assert.ok(c.receipts.some((r) => r.id === "ok0")); assert.ok(c.receipts.some((r) => r.id === "failed"));
    failed = false; await c.confirmImport();
    assert.equal(calls, 3); assert.equal(c.importing, null); assert.match(c.message, /51 new/);
  } finally { globalThis.atlasApexTest = original; }
});

test("legacy migration calls records then links and preserves completed receipts on failure", async () => {
  const c = new components.atlasTickets(); c.load = async () => {};
  const original = globalThis.atlasApexTest;
  const phases = [];
  globalThis.atlasApexTest = async (name, args) => {
    assert.equal(name, "importLegacy"); const chunk = JSON.parse(args.workspaceJson); phases.push(chunk.phase);
    if (chunk.phase === "links") throw Error("Missing epic");
    return JSON.stringify({ phase: chunk.phase, receiptId: "r1", saved: 1 });
  };
  try {
    const result = await c.importLegacy({ workspace: "fixture", taskAtlas: { items: [{ id: "one", summary: "Legacy" }] } });
    assert.deepEqual(phases, ["records", "links"]); assert.equal(result.complete, false); assert.equal(result.receipts.length, 1);
  } finally { globalThis.atlasApexTest = original; }
});

test("conversation waits for recovered draft hydration before exposing editable controls", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  let finish;
  globalThis.atlasApexTest = async (name) => name === "getConversation"
    ? JSON.stringify({ id: "one", messages: [], changes: [] })
    : new Promise((resolve) => { finish = resolve; });
  try {
    const loading = c.load(true); await Promise.resolve(); await Promise.resolve();
    assert.equal(c.ready, false);
    finish(JSON.stringify({ revision: 2, data: { paste: "Recovered reply" } })); await loading;
    assert.equal(c.ready, true); assert.equal(c.paste, "Recovered reply");
    const html = await readFile(join(root, "atlasConversation/atlasConversation.html"), "utf8");
    for (const handler of ["handleAnswer", "handleIdentity", "handleTicketNote"])
      assert.match(html, new RegExp(`on(?:input|change)=\\{${handler}\\} disabled=\\{busy\\}`));
    assert.match(html, /oninput=\{handlePaste\}><\/textarea>/);
  } finally { globalThis.atlasApexTest = original; }
});

test("conversation unlocks after foreground work without waiting for background draft saves", async () => {
  const c = new components.atlasConversation(); c.draftLoaded = true;
  const saves = []; let actions = 0;
  c.persistDraft = () => new Promise((resolve) => saves.push(resolve));
  await c.guard(async () => { actions++; });
  assert.equal(c.busy, false); assert.equal(saves.length, 1);
  await c.guard(async () => { actions++; });
  assert.equal(actions, 2); assert.equal(saves.length, 2);
  saves.forEach((finish) => finish());
});

test("every Work copy repeats the response ceiling, including old replies and each continuation", () => {
  const c = new components.atlasConversation();
  c.settings = {mine: {replyLimit: 1000}};
  c.conversationId = "uat-1";
  c.convo = {mode: "uat"};
  const reminder = /REPLY LIMIT: 14,000 characters.*atlas-response-part/;
  for (const kind of ["files", "results", "answers", "uat-plan", "uat-results", "old-saved"]) {
    c.showOutgoing(kind, `${kind} feedback`, "saved");
    assert.match(c.outgoing.parts[0].text, reminder, kind);
    assert.match(c.outgoing.parts[0].text, /UAT REQUEST ID: uat-1/);
  }
  c.showOutgoing("results", "long research ".repeat(300), "saved");
  assert.ok(c.outgoing.parts.length > 1);
  for (const part of c.outgoing.parts) {
    assert.ok(part.text.length <= 1000);
    assert.match(part.text, reminder);
  }
  const legacy = [
    "REMINDER: each response must be at most 14,000 characters. Split larger replies into separate responses.",
    'REMINDER: send Atlas JSON in a fenced json code block; keep prose outside. Serialize and validate it; preserve exact find text. For source edits, copy find from the latest backup/retrieve text for that file, never from memory. If missing, request it with "resend":true and wait before editing. Each response must be at most 14,000 characters including escaping, fences and prose. For longer JSON, use separately serialized atlas-response-part messages, each in its own fenced json block and separate response.',
  ];
  for (const mode of ["Source", "Task", "Files", "uat", "support-tickets"]) {
    c.convo = {mode};
    for (const footer of ["", ...legacy, c.outgoing.text.split("\n\n").at(-1)]) {
      const body = `Created file with literal REMINDER: embedded in content${footer ? "\n\n" + footer : ""}`;
      c.showOutgoing("old-saved", body, "saved");
      assert.equal((c.outgoing.text.match(/REPLY LIMIT:/g) || []).length, 1, `${mode}: ${footer}`);
      assert.equal((c.outgoing.text.match(/REMINDER: each response|REMINDER: send Atlas JSON/g) || []).length, 0);
      assert.ok(c.outgoing.text.startsWith("Created file with literal REMINDER: embedded in content"));
      if (mode === "uat") assert.match(c.outgoing.text, /UAT REQUEST ID: uat-1/);
      if (mode === "support-tickets") assert.match(c.outgoing.text, /SUPPORT TICKETS REQUEST ID: uat-1/);
      c.showOutgoing("reloaded", c.outgoing.text, "saved");
      assert.equal((c.outgoing.text.match(/REPLY LIMIT:/g) || []).length, 1, `${mode}: repeated`);
    }
  }
  const diagnostic = "REMINDER: send Atlas JSON failed at 14,000 characters using atlas-response-part; actual server evidence: line 42";
  c.convo = {mode: "Source"};
  c.showOutgoing("results", `ATLAS RESULTS\n${diagnostic}\n\n${c.outgoing.text.split("\n\n").at(-1)}`, "saved");
  assert.ok(c.outgoing.text.includes(diagnostic + "\n\nREPLY LIMIT:"), "A diagnostic resembling an old footer is still evidence.");
  const blankHeavy = "Document line" + "\n".repeat(60000) + "Closing line";
  c.settings.mine.replyLimit = 1000000;
  c.showOutgoing("files", blankHeavy + "\n\n" + c.outgoing.text.split("\n\n").at(-1), "saved");
  assert.ok(c.outgoing.text.startsWith(blankHeavy + "\n\nREPLY LIMIT:"));
});

test("a reply for the agent says whether Salesforce has saved it", async () => {
  const original = globalThis.atlasApexTest, oldStorage = globalThis.sessionStorage, values = new Map();
  let broken = false, saves = [], failAdd = false;
  globalThis.sessionStorage = {getItem: (k) => values.get(k), setItem: (k, v) => { if (broken) throw Error("QuotaExceededError"); values.set(k, v); }, removeItem: (k) => values.delete(k)};
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "addMessage") { if (failAdd) throw Error("Insufficient access"); return; }
    assert.equal(name, "appendMessages");
    const batch = JSON.parse(args.messagesJson);
    await new Promise((resolve, reject) => saves.push({resolve, reject}));
    return JSON.stringify(batch.map((m) => ({nonce: m.nonce, recordId: m.nonce})));
  };
  const panel = (id) => {
    const c = new components.atlasConversation();
    c.boot = {org: {id: "save-state-org"}, user: {id: "user"}}; c.conversationId = id; c.settings = {mine: {replyLimit: 100000}};
    return c;
  };
  const settle = async () => { for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve)); };
  try {
    // Queued with a browser copy: visible at once, but not called saved until Salesforce returns its receipt.
    const c = panel("save-state-queued"); c.deferMessages = true;
    await c.send("results", "queued reply");
    assert.match(c.outgoing.parts[0].text, /^queued reply\n\nREPLY LIMIT: 14,000 characters/); assert.equal(c.outgoing.state, "queued");
    assert.match(c.outgoingSave.text, /Shown before Salesforce has saved it/);
    saves.shift().resolve(); await settle();
    assert.equal(c.outgoing.state, "saved"); assert.match(c.outgoingSave.text, /Saved in this conversation's history/);

    // A failed history save leaves the reply visible and says it is not saved; a retry that lands saves it.
    c.send("results", "retry me"); await settle();
    saves.shift().reject(Error("Row lock")); await settle();
    assert.equal(c.outgoing.state, "queued"); assert.match(c.outgoingSave.text, /Not saved in Salesforce yet/);
    assert.match(c.historyStatus, /History NOT saved: Row lock/);
    const retry = c.outbox.flush(); await settle(); saves.shift().resolve(); await retry; await settle();
    assert.equal(c.outgoing.state, "saved");

    // Without browser storage the queued reply exists only in this tab until Salesforce saves it.
    broken = true;
    const memory = panel("save-state-memory"); memory.deferMessages = true;
    const waiting = memory.send("results", "memory reply"); await settle();
    assert.match(memory.outgoingSave.text, /Not saved in Salesforce yet/);
    assert.match(memory.historyStatus, /held only in this tab/);
    saves.shift().resolve(); await waiting; await settle();
    assert.equal(memory.outgoing.state, "saved"); assert.equal(memory.historyStatus, "History saved in Salesforce.");
    broken = false;

    // A direct write is "saving" until it returns, and "failed" if it does not.
    const direct = panel("save-state-direct");
    await direct.send("correction", "direct reply"); assert.equal(direct.outgoing.state, "saved");
    failAdd = true;
    await assert.rejects(direct.send("correction", "lost reply"), /Insufficient access/);
    assert.match(direct.outgoing.parts[0].text, /^lost reply\n\nREPLY LIMIT: 14,000 characters/); assert.equal(direct.outgoing.state, "failed");
    assert.match(direct.outgoingSave.text, /NOT saved in Salesforce/);

    // A reply too large for the history queue is shown, and marked unsaved.
    const big = panel("save-state-big"); big.deferMessages = true;
    assert.throws(() => big.queueOutgoing("results", "x".repeat(1500001)), /1,500,000/);
    assert.equal(big.outgoing.state, "failed");
    for (const p of [c, memory, direct, big]) p.unsubscribeHistory?.();
  } finally { globalThis.atlasApexTest = original; globalThis.sessionStorage = oldStorage; }
});

test("research and local questions finish while history writes wait, and newer paste survives", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest, oldStorage = globalThis.sessionStorage;
  const values = new Map();
  globalThis.sessionStorage = {getItem: (k) => values.get(k), setItem: (k, v) => values.set(k, v), removeItem: (k) => values.delete(k)};
  c.boot = {org: {id: "performance-org"}, user: {id: "user"}};
  c.conversationId = "performance-conversation"; c.settings = {mine: {replyLimit: 100000}};
  c.template = {querySelector: () => ({value: ""})};
  let save, read, reads = 0;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "appendMessages") { await new Promise((resolve) => {save = resolve;}); return JSON.stringify(JSON.parse(args.messagesJson).map((m) => ({nonce: m.nonce, recordId: m.nonce}))); }
    assert.equal(name, "run"); reads++;
    if (reads === 1) await new Promise((resolve) => {read = resolve;});
    return JSON.stringify({value: reads});
  };
  try {
    c.paste = JSON.stringify({type: "atlas-questions", questions: [{id: "one", question: "Which region?"}]});
    await c.processPaste(); assert.equal(c.busy, false); assert.equal(c.questions.length, 1);
    const request = JSON.stringify({type: "atlas-request", requests: [{id: "one", op: "soql", query: "SELECT Id FROM Account"}]});
    c.paste = request; const running = c.processPaste();
    while (!read) await new Promise((resolve) => setImmediate(resolve));
    c.paste = "new reply typed while waiting"; read(); await running;
    assert.equal(c.paste, "new reply typed while waiting"); assert.equal(c.busy, false);
    assert.match(c.outgoing.parts[0].text, /Fetched from Salesforce/);
    c.paste = request; await c.processPaste(); assert.equal(reads, 1);
    assert.match(c.outgoing.parts[0].text, /REUSED snapshot/);
    await c.orgWrite(async () => {});
    c.paste = request; await c.processPaste(); assert.equal(reads, 2);
    const flushing = c.outbox.flush();
    while (c.outbox.pending.length) { save(); await new Promise((resolve) => setImmediate(resolve)); }
    await flushing;
  } finally { c.unsubscribeHistory?.(); globalThis.atlasApexTest = original; globalThis.sessionStorage = oldStorage; }
});

test("saving generated Files invalidates repeated research even when the save response fails", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest, oldWindow = globalThis.window;
  c.boot = {org: {id: "file-cache-org"}, user: {id: "user"}};
  c.settings = {mine: {replyLimit: 100000}}; c.artifactsJson = '[{}]';
  c.deferMessages = true; c.outbox = {enqueue: async () => {}};
  globalThis.window = {AtlasFiles: {buildFile: async () => ({name: "atlas-test.txt", base64: "eA=="})}};
  let reads = 0, fail = false;
  globalThis.atlasApexTest = async (name) => {
    if (name === "saveFile") {if (fail) throw Error("response lost"); return "version";}
    assert.equal(name, "run"); return JSON.stringify({count: ++reads});
  };
  const request = {requests: [{id: "files", op: "soql", query: "SELECT Id FROM ContentVersion"}]};
  try {
    await c.runRequests(request); await c.runRequests(request); assert.equal(reads, 1);
    for (fail of [false, true]) {
      await c.saveToSalesforce({currentTarget: {dataset: {index: 0}}});
      await c.runRequests(request);
    }
    assert.equal(reads, 3);
  } finally {globalThis.atlasApexTest = original; globalThis.window = oldWindow;}
});

test("research and backups send each unchanged file once, until the rules reminder", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.boot = {org: {id: "sent-files-org"}, user: {id: "user"}, people: []};
  c.settings = {mine: {replyLimit: 100000}, jira: {}}; c.convo = {id: "convo", title: "T", mode: "Source", changes: []};
  const bodies = []; c.deferMessages = true; c.outbox = {enqueue: async (m) => bodies.push(m.body)};
  let text = "class Foo {}";
  c.waitForRetrieve = async () => ({done: true, files: [{path: "classes/Foo.cls", text}]});
  globalThis.atlasApexTest = async (name) => {
    if (name === "run") return JSON.stringify({asyncId: "R"});
    if (name === "startBackup") return JSON.stringify({change: {id: "change", name: "CHG-1"}, asyncId: "B"});
    assert.equal(name, "backupStatus");
    return JSON.stringify({done: true, change: {name: "CHG-1", found: [], missing: [], backupUrl: "/b"}, files: [{path: "classes/Foo.cls", text}]});
  };
  c.downloadUrl = () => {};
  const retrieve = (extra = {}) => c.runRequests({requests: [{id: "r", op: "retrieve", components: [{type: "ApexClass", name: "Foo"}], fresh: true, ...extra}]});
  try {
    await retrieve(); assert.match(bodies.at(-1), /class Foo \{\}/);
    await retrieve(); assert.match(bodies.at(-1), /unchanged: same text as sent at/); assert.doesNotMatch(bodies.at(-1), /class Foo \{\}/);
    await c.backup({components: [{type: "ApexClass", name: "Foo"}]}); assert.match(bodies.at(-1), /BACKUP SAVED[\s\S]*unchanged/);
    await retrieve({resend: true}); assert.match(bodies.at(-1), /class Foo \{\}/);
    text = "class Foo { }"; await retrieve(); assert.match(bodies.at(-1), /class Foo \{ \}/, "Changed text is sent in full");
    assert.ok(c.draftData().sentFiles["classes/Foo.cls"], "The memory is saved with the conversation");
    await c.remindRules(); assert.deepEqual(c.sentFiles, {});
    await retrieve(); assert.match(bodies.at(-1), /class Foo \{ \}/, "After a rules reminder every file is sent again");
    const restored = new components.atlasConversation(); restored.applyDraft(c.draftData());
    assert.deepEqual(restored.sentFiles, c.sentFiles);
  } finally { globalThis.atlasApexTest = original; }
});

test("deployment results show the exact handoff Salesforce saved for the agent", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.boot = {org: {id: "handoff-org"}, user: {id: "user"}}; c.settings = {mine: {replyLimit: 100000}}; c.connected = true;
  globalThis.atlasApexTest = async (name) => {
    assert.equal(name, "deployStatus");
    return JSON.stringify({done: true, change: {name: "CHG-1", revision: 1, status: "Deployed", result: {success: "true"}}, result: {success: "true"}, message: "I approved and DEPLOYED CHG-1 revision 1.\nSERVER TEXT"});
  };
  try {
    await c.finishDeploy("change");
    assert.match(c.outgoing.parts[0].text, /^I approved and DEPLOYED CHG-1 revision 1\.\nSERVER TEXT\n\nREPLY LIMIT: 14,000 characters/);
  } finally { globalThis.atlasApexTest = original; }
});

test("source rejection displays the transactional handoff without a second message write", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.review = {id: "change", name: "CHG-1", revision: 2}; c.settings = {mine: {replyLimit: 100000}};
  c.load = async () => {};
  const methods = [];
  globalThis.atlasApexTest = async (name) => {
    methods.push(name);
    assert.equal(name, "decideConfirmed");
    return JSON.stringify({id: "change", name: "CHG-1", revision: 2, status: "Rejected"});
  };
  try {
    await c.handleDecide({detail: {approve: false, note: "Keep the original"}});
    assert.equal(c.problem, null); assert.equal(c.review, null);
    assert.match(c.outgoing.parts[0].text, /REJECTED CHG-1 revision 2/);
    assert.match(c.outgoing.parts[0].text, /Keep the original/);
    assert.deepEqual(methods, ["decideConfirmed"]);
  } finally { globalThis.atlasApexTest = original; }
});

test("a failed agent operation keeps its pasted reply available to retry", async () => {
  const component = new components.atlasConversation();
  const pasted = '{"type":"atlas-request","requests":[{"op":"soql","query":"SELECT Id FROM Account"}]}';
  component.paste = pasted;
  const input = { value: pasted };
  component.template = { querySelector: () => input };
  component.outbox = {enqueue: async () => {}, flush: async () => {}};
  component.runRequests = async () => { throw Error("Temporary failure"); };
  await component.processPaste();
  assert.equal(component.problem.text, "Temporary failure");
  assert.equal(component.paste, pasted);
  assert.equal(input.value, pasted);
});

test("new conversation resumes unsent work; failed replacement preserves both drafts", async () => {
  const c = new components.atlasWork(), original = globalThis.atlasApexTest;
  const store = browserDraftStore(); c.boot = draftBoot; c.connected = true;
  c.form = {mode:"Task",title:"Unsent",request:"Keep everything",future:{value:true}};
  c.attachments = [{name:"original.txt",text:"full",warnings:["Some formatting omitted"]}];
  c.newConversation();
  assert.equal(c.form.request, "Keep everything");
  c.openRequest = {draft:{mode:"Source",title:"Incoming",request:"Other work"}};
  assert.equal(c.pendingDrafts.length, 1);
  assert.match(c.attachmentRows[0].warning, /formatting/);
  globalThis.atlasApexTest = async () => { throw Error("Save failed"); };
  try {
    await c.openPendingDraft();
    assert.equal(c.form.title,"Unsent"); assert.equal(c.pendingDrafts.length,1);
    assert.equal(c.attachments[0].text,"full");
    globalThis.atlasApexTest = async (name,args) => {
      if (name === "reserveRecovery") return JSON.stringify({id: "reserved", revision: 0});
      assert.equal(name,"saveEntry");
      const saved=JSON.parse(args.dataJson);
      assert.equal(saved.future.value,true); assert.equal(saved.attachments[0].text,"full");
      return JSON.stringify({id:"saved",revision:1});
    };
    await c.openPendingDraft();
    assert.equal(c.form.title,"Incoming"); assert.equal(c.pendingDrafts.length,0);
  } finally { globalThis.atlasApexTest = original; store.restore(); }
});

test("an incoming Work draft before connection cannot overwrite browser recovery", () => {
  const c = new components.atlasWork(), original = globalThis.sessionStorage;
  const prior = JSON.stringify({ form: { mode: "Task", title: "Browser draft", request: "Keep me" }, attachments: [{ name: "kept.txt" }], nonce: "old", pendingDrafts: [] });
  let stored = prior;
  globalThis.sessionStorage = { getItem: () => stored, setItem: (_, value) => { stored = value; } };
  c.boot = {org: {id: "org"}, user: {id: "user"}};
  c.loadPage = () => {};
  try {
    c.openRequest = { draft: { title: "Incoming", request: "Also keep" } };
    assert.equal(stored, prior, "The setter must not replace storage before hydration");
    c.connectedCallback();
    assert.equal(c.form.title, "Browser draft"); assert.equal(c.attachments[0].name, "kept.txt");
    assert.equal(c.pendingDrafts[0].title, "Incoming");
    assert.equal(JSON.parse(stored).form.request, "Keep me");
    assert.equal(JSON.parse(stored).pendingDrafts[0].request, "Also keep");
  } finally { globalThis.sessionStorage = original; }
});

test("uncertain conversation starts retry the identical nonce and payload", async () => {
  const store=browserDraftStore(), c=new components.atlasWork(), original=globalThis.atlasApexTest, sent=[];
  c.form={mode:"Task",title:"Retry me",request:"Exact request"}; c.settings={mine:{},jira:{}}; c.boot={...draftBoot,people:[]}; c.connected=true;
  globalThis.atlasApexTest=async (name,args)=>{assert.equal(name,"startConversationChecked"); sent.push(structuredClone(args)); if(sent.length===1) throw Error("Lost response"); return "a01000000000001AAA";};
  try {
    await c.start(); assert.ok(c.startPending);
    // The identity a reload would retry with was saved before the request left.
    assert.deepEqual(JSON.parse(store.entries.get(c.draftKey)).startPending, sent[0]);
    c.handleField({target:{name:"request"},detail:{value:"Must not replace"}});
    assert.equal(c.form.request,"Exact request");
    await c.start(); assert.deepEqual(sent[0],sent[1]);
    assert.equal(c.selectedId,"a01000000000001AAA"); assert.equal(c.form.request,""); assert.equal(c.startPending,null);
  } finally {store.restore(); globalThis.atlasApexTest=original;}
});

test("a conversation start whose retry identity cannot be saved sends nothing", async () => {
  const store=browserDraftStore(), original=globalThis.atlasApexTest, set=globalThis.sessionStorage.setItem, sent=[];
  let broken=true;
  globalThis.sessionStorage.setItem=(k,v)=>{ if(broken) throw Error("QuotaExceededError"); set(k,v); };
  globalThis.atlasApexTest=async (name,args)=>{sent.push(args); return "a01000000000001AAA";};
  try {
    const c=new components.atlasWork(); c.boot={...draftBoot,people:[]}; c.settings={mine:{},jira:{}}; c.connected=true;
    c.form={mode:"Task",title:"Keep me",request:"Exact request"};
    await c.start();
    assert.equal(sent.length,0); assert.match(c.error,/was not started.*Nothing was sent to Salesforce/);
    // Nothing was sent, so the form stays editable and its next start builds a fresh request.
    assert.equal(c.startPending,null); assert.equal(c.editingLocked,false); assert.equal(c.form.request,"Exact request");
    broken=false; await c.start();
    assert.equal(sent.length,1); assert.equal(c.selectedId,"a01000000000001AAA");
    // A start that may already have reached Salesforce keeps its exact identity.
    const retry=new components.atlasWork(); retry.boot={...draftBoot,people:[]}; retry.settings={mine:{},jira:{}}; retry.connected=true;
    const pinned={conversationJson:"{}",prompt:"exact",nonce:"receipt"}; retry.startPending=pinned; retry.nonce="receipt";
    broken=true; await retry.start();
    assert.equal(sent.length,1); assert.equal(retry.startPending,pinned); assert.equal(retry.editingLocked,true);
    assert.match(retry.error,/Download the draft/);
  } finally {store.restore(); globalThis.atlasApexTest=original;}
});

test("only explicit immutable Start rejection unlocks corrections and preserves attachments", async () => {
  const store = browserDraftStore(), original = globalThis.atlasApexTest;
  try {
    for (const oversized of ["title", "attachment"]) {
      const c = new components.atlasWork(); c.boot = {...draftBoot, people: []}; c.settings = {mine: {}, jira: {}}; c.connected = true;
      c.form = {mode: "Task", title: oversized === "title" ? "x".repeat(81) : "Atlas long attachment", request: "Keep the request"};
      c.attachments = [{name: "large.txt", key: "large", text: "x".repeat(2 * 1024 * 1024), warnings: []}];
      c.startPending = {conversationJson: JSON.stringify(c.form), prompt: "pinned", nonce: "old-receipt"}; c.nonce = "old-receipt";
      globalThis.atlasApexTest = async () => JSON.stringify({code: "ATLAS_START_INPUT_REJECTED", message: "Shorten the input; nothing started."});
      await c.start();
      assert.equal(c.startPending, null); assert.equal(c.editingLocked, false); assert.equal(c.attachments[0].text.length, 2 * 1024 * 1024);
      assert.equal(c.form.request, "Keep the request"); assert.notEqual(c.nonce, "old-receipt");
      assert.equal(JSON.parse(store.entries.get(c.draftKey)).startPending, null);
      c.handleField({target: {name: "title"}, detail: {value: "Atlas corrected"}});
      c.removeAttachment({currentTarget: {dataset: {key: "large"}}}); assert.equal(c.attachments.length, 0);
      globalThis.atlasApexTest = async () => "a01000000000001AAA";
      await c.start(); assert.equal(c.selectedId, "a01000000000001AAA");
    }
    const c = new components.atlasWork(); c.boot = {...draftBoot, people: []}; c.connected = true;
    c.startPending = {conversationJson: "{}", prompt: "exact", nonce: "receipt"};
    const pinned = c.startPending;
    for (const reply of [null, "invalid", '{"code":"ATLAS_START_INPUT_REJECTED"}', '{"code":"OTHER","message":"no"}']) {
      let asked = false;
      globalThis.atlasApexTest = async () => { asked = true; return reply; };
      await c.start(); assert.equal(asked, true); assert.equal(c.startPending, pinned); assert.equal(c.editingLocked, true);
    }
  } finally { store.restore(); globalThis.atlasApexTest = original; }
});

test("Work never reads or writes recovery without both org and user scope", () => {
  const store = browserDraftStore();
  try {
    store.entries.set("null", "invalid");
    const c = new components.atlasWork(); c.loadPage = () => {}; c.connectedCallback(); c.cacheDraft();
    assert.equal(c.draftKey, null); assert.equal(c.hydrated, false); assert.equal(store.entries.size, 1);
    c.boot = draftBoot;
    store.entries.set(c.draftKey, JSON.stringify({form: {title: "Scoped"}, attachments: []}));
    c.connectedCallback(); assert.equal(c.form.title, "Scoped"); c.cacheDraft();
    assert.equal(store.entries.size, 2);
  } finally { store.restore(); }
});

test("Tickets rejects malformed browser recovery atomically and hydrates once on reconnect", () => {
  const store = browserDraftStore();
  try {
    for (const invalid of [{importing: {rows: {}}}, {exporting: {phase: "children", tickets: [null], blocked: []}}, {editor: {ticket: {id: "t"}, editing: null, savedEditing: "{}"}}, {receipts: [null]}]) {
      const c = new components.atlasTickets(); c.boot = draftBoot; c.load = () => {};
      store.entries.set(c.recoveryKey, JSON.stringify({version: 1, pendingRecoveries: [], receipts: [], ...invalid}));
      c.connectedCallback(); assert.equal(c.selected, undefined); assert.equal(c.importing, undefined); assert.equal(c.exporting, undefined);
      assert.match(c.recoveryStatus, /could not be read/);
    }
    const c = new components.atlasTickets(); c.boot = draftBoot; c.load = () => {};
    store.entries.set(c.recoveryKey, JSON.stringify({version: 1, pendingRecoveries: [{marker: "kept"}], receipts: []}));
    c.connectedCallback(); c.disconnectedCallback(); c.connectedCallback();
    assert.equal(c.pendingRecoveries.length, 1);
  } finally { store.restore(); }
});

test("ticket checklist and navigation never overwrite unsaved editor changes", async () => {
  const c=new components.atlasTickets(); c.selected={id:"one"}; c.editing={summary:"Original"}; c.savedEditing=JSON.stringify(c.editing);
  c.handleEdit({target:{name:"summary",type:"text"},detail:{value:"Unsaved"}});
  c.closeTicket(); assert.equal(c.selected.id,"one");
  await c.finishUpdate({currentTarget:{dataset:{id:"u",part:"field:summary",done:"true"}}});
  assert.equal(c.editing.summary,"Unsaved"); assert.match(c.error,/Save the ticket edits/);
});

function recoveryStore(c, saved) {
  c.saveRecovery = async (data) => {
    const id = `recovery-${saved.size}`;
    saved.set(id, structuredClone({ type: "atlas-jira-operation", version: 1, ...data }));
    return { id, versionId: id };
  };
  c.load = async () => {};
}

test("CSV exports pin the exact request before mutation and replay after reload", async () => {
  const c = new components.atlasTickets(), saved = new Map(), original = globalThis.atlasApexTest;
  recoveryStore(c, saved);
  c.exporting = { phase: "epics", tickets: [{ id: "one", version: "v1" }], blocked: [], count: 1, remaining: 0 };
  const requests = []; let reads = 0;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "getTicket") { reads++; return { id: "one", version: "v1", summary: "Exact", issueType: "Epic" }; }
    assert.equal(name, "saveExport"); assert.ok(saved.size, "Recovery persisted before export mutation");
    requests.push(args.exportJson);
    if (requests.length === 1) throw Error("Response lost after commit");
    return JSON.stringify({ fileId: "csv", receiptId: "receipt" });
  };
  const oldTimeout = globalThis.setTimeout;
  try {
    await c.downloadExport(); assert.match(c.error, /lost/); assert.ok(c.exporting.pending);
    c.startExport(); assert.ok(c.exporting.pending, "A new plan cannot overwrite uncertain submission");
    const resumed = new components.atlasTickets(); recoveryStore(resumed, saved);
    resumed.recoveryDraft = saved.values().next().value;
    await resumed.resumeRecovery();
    assert.ok(resumed.exporting.pending); assert.equal(requests.length, 1, "Restore never submits");
    const link = { click() {}, removeAttribute() {} }; resumed.template = { querySelector: () => link };
    globalThis.setTimeout = (callback) => { callback(); return 0; };
    await resumed.downloadExport();
    assert.equal(resumed.error, null); assert.equal(resumed.exporting, null);
    assert.equal(reads, 1, "Retry must not reload changed tickets or regenerate a batch");
    assert.equal(requests[0], requests[1]);
    assert.ok(resumed.receipts.some((r) => r.id === "receipt"));
  } finally { globalThis.atlasApexTest = original; globalThis.setTimeout = oldTimeout; }
});

test("CSV exports read six tickets at a time, keep board order and stop on a changed ticket", async () => {
  const c = new components.atlasTickets(), saved = new Map(), original = globalThis.atlasApexTest;
  recoveryStore(c, saved);
  const tickets = Array.from({ length: 13 }, (_, i) => ({ id: `t${i}`, atlasId: `TKT-${i}`, version: "v1" }));
  c.exporting = { phase: "epics", tickets, blocked: [], count: tickets.length, remaining: 0 };
  let active = 0, most = 0, exported = null, changed = null;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "getTicket") {
      active++; most = Math.max(most, active);
      const index = Number(args.ticketId.slice(1));
      await new Promise((resolve) => setTimeout(resolve, (13 - index) % 5));
      active--;
      return { id: args.ticketId, version: args.ticketId === changed ? "v2" : "v1", summary: args.ticketId, issueType: "Epic" };
    }
    assert.equal(name, "saveExport"); exported = JSON.parse(args.exportJson);
    return JSON.stringify({ fileId: "csv", receiptId: "receipt" });
  };
  const link = { click() {}, removeAttribute() {} }; c.template = { querySelector: () => link };
  try {
    changed = "t9";
    await c.downloadExport();
    assert.match(c.error, /TKT-9 changed/); assert.equal(exported, null, "a changed ticket stops the export before it is saved");
    assert.equal(c.exporting.pending, undefined);
    changed = null; c.error = null;
    active = 0; most = 0;
    await c.downloadExport();
    assert.equal(c.error, null); assert.ok(most > 1 && most <= 6, `read ${most} at once`);
    assert.deepEqual(Object.keys(exported.versions), tickets.map((t) => t.id));
  } finally { globalThis.atlasApexTest = original; }
});

test("an import reload resumes a pinned manifest and never repeats committed chunks unnecessarily", async () => {
  const c = new components.atlasTickets(), saved = new Map(), original = globalThis.atlasApexTest;
  recoveryStore(c, saved); const chunks = []; let fail = true;
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "beginImport") return "manifest";
    if (name === "loadVersion") return JSON.stringify({ dataJson: JSON.stringify(saved.get(args.versionId)) });
    assert.equal(name, "importJira"); const request = JSON.parse(args.rowsJson); chunks.push(request.chunk);
    assert.ok([...saved.values()].some((s) => s.review?.manifestId === "manifest"));
    if (request.chunk === 1 && fail) throw Error("Network disconnected");
    return JSON.stringify({ applied: true, created: request.rows.length, receiptId: "chunk-" + request.chunk });
  };
  try {
    const csv = "Issue key,Summary\n" + Array.from({ length: 51 }, (_, i) => `DEMO-${i + 1},Row ${i}`).join("\n");
    await c.importFile({ target: { files: [{ text: async () => csv }] } });
    assert.equal(c.importReviewRows.length, 50); c.nextImportPage(); assert.equal(c.importReviewRows.length, 1);
    await c.confirmImport(); assert.equal(c.importing.next, 50);
    const checkpoint = [...saved.values()].find((s) => s.operation === "import-progress"); assert.equal(checkpoint.next, 50);
    const frozen = JSON.stringify(c.importing.rows);
    c.handleImportChoice({ target: { dataset: { key: "DEMO-51", field: "resolution" } }, detail: { value: "new" } });
    assert.equal(JSON.stringify(c.importing.rows), frozen);
    await c.importFile({ target: { files: [{ text: async () => "Issue key,Summary\nDEMO-99,Replacement" }] } });
    assert.match(c.error, /previous review has been kept/); assert.equal(c.importing.rows.length, 51);
    const resumed = new components.atlasTickets(); recoveryStore(resumed, saved); resumed.recoveryDraft = checkpoint;
    await resumed.resumeRecovery(); assert.equal(resumed.error, null); assert.equal(resumed.importing.next, 50);
    fail = false; await resumed.confirmImport();
    assert.deepEqual(chunks, [0, 1, 1]); assert.equal(resumed.importing, null); assert.match(resumed.message, /51 new/);
  } finally { globalThis.atlasApexTest = original; }
});

test("failed checkpoint writes stop before mutation and preserve both current and queued work", async () => {
  const c = new components.atlasTickets(), original = globalThis.atlasApexTest;
  let mutations = 0;
  globalThis.atlasApexTest = async (name) => { if (name === "beginImport") return "manifest"; mutations++; };
  c.saveRecovery = async () => { throw Error("Storage unavailable"); };
  try {
    await c.importFile({ target: { files: [{ text: async () => "Issue key,Summary\nDEMO-1,Keep" }] } });
    assert.equal(c.importing.rows[0].summary, "Keep");
    await c.confirmImport(); assert.equal(mutations, 0); assert.match(c.error, /Storage unavailable/);
    c.recoveryDraft = { type: "atlas-jira-operation", version: 1, operation: "import" };
    await c.resumeRecovery(); assert.match(c.error, /queued/); assert.equal(c.pendingRecoveries.length, 1);
    await c.cancelImport(); assert.ok(c.importing, "Closing cannot lose a review when persistence fails");
  } finally { globalThis.atlasApexTest = original; }
});

test("ticket editor fields stay disabled until initial File history finishes loading", async () => {
  const html = await readFile(join(root, "atlasTickets/atlasTickets.html"), "utf8");
  const fields = html.match(/<lightning-(?:input|textarea|combobox)\b[^>]*onchange=\{handleEdit\}[^>]*>/g);
  assert.ok(fields.length > 0);
  for (const field of fields) assert.match(field, /disabled=\{busy\}/);
  const c = new components.atlasTickets(), saved = new Map(), original = globalThis.atlasApexTest;
  recoveryStore(c, saved);
  let finishFiles;
  globalThis.atlasApexTest = async (name) => {
    if (name === "getTicket") return { id: "one", version: "v1", summary: "Original" };
    assert.equal(name, "ticketFiles");
    return new Promise((resolve) => { finishFiles = resolve; });
  };
  try {
    const opening = c.openTicket({ currentTarget: { dataset: { id: "one" } } });
    await Promise.resolve(); await Promise.resolve();
    assert.equal(c.selected.id, "one"); assert.equal(c.busy, true);
    finishFiles(JSON.stringify({ files: [], nextCursor: null })); await opening;
    assert.equal(c.busy, false);
    c.handleEdit({ target: { name: "blockerNote", type: "textarea" }, detail: { value: "Keep this blocker" } });
    await c.saveAndCloseEditor();
    c.recoveryDraft = saved.values().next().value; await c.resumeRecovery();
    assert.equal(c.editing.blockerNote, "Keep this blocker");
  } finally { globalThis.atlasApexTest = original; }
});

function browserDraftStore() {
  const previous = globalThis.sessionStorage, entries = new Map();
  globalThis.sessionStorage = { getItem: (key) => entries.get(key) ?? null, setItem: (key, value) => entries.set(key, value), removeItem: (key) => entries.delete(key) };
  return { entries, restore: () => { globalThis.sessionStorage = previous; } };
}
const draftBoot = { org: { id: "org" }, user: { id: "user" } };

test("Jira reconciliation choices survive an immediate reload before cloud debounce", async () => {
  const store = browserDraftStore(), c = new components.atlasTickets();
  c.boot = draftBoot; c.load = async () => {}; c.connectedCallback();
  c.importing = { rows: [{ key: "DEMO-1", candidates: [{ id: "ticket", version: "v2" }], resolution: "", needsMatch: true }], skipped: [], totals: {}, next: 0 };
  c.handleImportChoice({ target: { dataset: { key: "DEMO-1", field: "resolution" } }, detail: { value: "ticket" } });
  clearTimeout(c.recoveryTimer);
  try {
    const reloaded = new components.atlasTickets(); reloaded.boot = draftBoot; reloaded.load = async () => {};
    reloaded.recoveryDraft = { operation: "editor", marker: "incoming" };
    reloaded.connectedCallback();
    assert.equal(reloaded.importing.rows[0].resolution, "ticket");
    assert.equal(reloaded.importing.rows[0].expectedVersion, "v2");
    assert.equal(reloaded.pendingRecoveries[0].marker, "incoming");
    assert.match(reloaded.recoveryStatus, /nothing was applied/);
  } finally { store.restore(); }
});

test("ticket editor autosave uses immutable serialized snapshots and preserves optimistic versions", async () => {
  const store = browserDraftStore(), c = new components.atlasTickets(), saved = [];
  c.boot = draftBoot; c.selected = { id: "t", version: "v1" }; c.editing = { summary: "Original" }; c.savedEditing = JSON.stringify(c.editing);
  let finish;
  c.saveRecovery = async (data) => { saved.push(structuredClone(data)); if (saved.length === 1) await new Promise((resolve) => { finish = resolve; }); return { id: "d" }; };
  try {
    c.handleEdit({ target: { name: "summary" }, detail: { value: "First" } });
    const first = c.flushRecovery(); await Promise.resolve();
    c.handleEdit({ target: { name: "summary" }, detail: { value: "Second" } });
    const second = c.flushRecovery();
    assert.equal(saved.length, 1); finish(); await first; await second;
    assert.deepEqual(saved.map((s) => s.editing.summary), ["First", "Second"]);
    assert.ok(saved.every((s) => s.ticket.version === "v1"));
    assert.equal(JSON.parse(store.entries.get(c.recoveryKey)).editor.editing.summary, "Second");
    await c.flushRecovery(); assert.equal(saved.length, 2, "Unchanged drafts do not create redundant snapshots");
  } finally { clearTimeout(c.recoveryTimer); store.restore(); }
});

test("a slow import draft save cannot pin an older receipt to newer choices", async () => {
  const c = new components.atlasTickets();
  c.importing = { rows: [{ key: "DEMO-1", candidates: [], resolution: "" }], skipped: [], totals: {}, next: 0 };
  let finish; c.saveRecovery = () => new Promise((resolve) => { finish = resolve; });
  const saving = c.preserveImport();
  c.handleImportChoice({ target: { dataset: { key: "DEMO-1", field: "resolution" } }, detail: { value: "new" } });
  finish({ id: "old" }); await saving;
  assert.equal(c.importing.source, null);
  assert.equal(c.importing.rows[0].resolution, "new");
});

test("failed autosave retains the browser copy and reports failure without modifying tickets", async () => {
  const store = browserDraftStore(), c = new components.atlasTickets(); c.boot = draftBoot;
  c.selected = { id: "t", version: "v1" }; c.editing = { summary: "Original" }; c.savedEditing = JSON.stringify(c.editing);
  c.saveRecovery = async () => { throw Error("Offline"); };
  try {
    c.handleEdit({ target: { name: "summary" }, detail: { value: "Keep me" } });
    await assert.rejects(c.flushRecovery(), /Offline/);
    assert.match(c.recoveryStatus, /NOT saved/);
    assert.equal(JSON.parse(store.entries.get(c.recoveryKey)).editor.editing.summary, "Keep me");
    assert.equal(c.selected.version, "v1");
  } finally { clearTimeout(c.recoveryTimer); store.restore(); }
});

test("detached ticket and conversation panels never overwrite a newer local recovery", async () => {
  const store = browserDraftStore();
  try {
    const ticket = new components.atlasTickets(); ticket.boot = draftBoot; ticket.connected = false;
    store.entries.set(ticket.recoveryKey, "new ticket work"); ticket.cacheRecovery();
    assert.equal(store.entries.get(ticket.recoveryKey), "new ticket work");
    const c = new components.atlasConversation(); c.boot = draftBoot; c.conversationId = "conversation"; c.draftLoaded = true; c.paste = "old";
    const original = globalThis.atlasApexTest;
    let finish; globalThis.atlasApexTest = () => new Promise((resolve) => { finish = resolve; });
    try {
      const pending = c.persistDraft(); await Promise.resolve(); c.connected = false;
      store.entries.set(c.draftKey, "new conversation work"); finish(1); await pending;
      assert.equal(store.entries.get(c.draftKey), "new conversation work");
      c.cacheDraft(); assert.equal(store.entries.get(c.draftKey), "new conversation work");
    } finally { globalThis.atlasApexTest = original; }
  } finally { store.restore(); }
});

test("conversation history is built once per message list", () => {
  const c = new components.atlasConversation();
  c.convo = { messages: [{ id: "a", direction: "To Agent", created: 1 }, { id: "b", direction: "From Agent", created: 2 }], changes: [] };
  const first = c.history;
  assert.equal(c.history, first);
  assert.deepEqual(first.map((m) => m.id), ["b", "a"]);
  assert.equal(first[0].who, "Agent → Atlas");
  c.convo = { ...c.convo, messages: [...c.convo.messages, { id: "c", direction: "To Agent", created: 3 }] };
  assert.notEqual(c.history, first); assert.equal(c.history[0].id, "c");
});

test("conversation autosave skips unchanged JSON and ignores a disconnected initial fetch", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  let writes = 0;
  globalThis.atlasApexTest = async () => ++writes;
  try {
    c.draftLoaded = true; c.paste = "Work";
    await c.persistDraft(); await c.persistDraft(); assert.equal(writes, 1);
    const other = new components.atlasConversation(); let finish;
    globalThis.atlasApexTest = (name) => name === "getState" ? Promise.resolve('{"revision":0,"data":{}}') : new Promise((resolve) => { finish = resolve; });
    const loading = other.load(true); other.disconnectedCallback();
    finish(JSON.stringify({ id: "old", messages: [], changes: [] })); await loading;
    assert.equal(other.convo, undefined); assert.equal(other.draftLoaded, false);
  } finally { globalThis.atlasApexTest = original; }
});

test("Work reconnects once, rejects malformed recovery and never erases a newer panel's draft", async () => {
  const store = browserDraftStore(), original = globalThis.atlasApexTest;
  try {
    const c = new components.atlasWork(); c.boot = draftBoot; c.loadPage = () => {};
    store.entries.set(c.draftKey, JSON.stringify({form: null, attachments: {bad: true}}));
    c.connectedCallback(); assert.equal(c.form.title, ""); assert.match(c.savedNotice, /unavailable/);
    c.form = {mode: "Task", title: "Keep", request: "Exact"}; c.pendingDrafts = [{title: "Pending"}];
    c.cacheDraft(); c.disconnectedCallback(); c.connectedCallback();
    assert.equal(c.pendingDrafts.length, 1, "Reconnection must not duplicate the cached queue");
    c.settings = {mine: {}, jira: {}}; c.boot = {...draftBoot, people: []};
    let finish; globalThis.atlasApexTest = () => new Promise((resolve) => { finish = resolve; });
    const starting = c.start(); await Promise.resolve(); c.disconnectedCallback();
    store.entries.set(c.draftKey, "newer work"); finish("a01000000000001AAA"); await starting;
    assert.equal(store.entries.get(c.draftKey), "newer work");
    c.cacheDraft(); assert.equal(store.entries.get(c.draftKey), "newer work");
  } finally { globalThis.atlasApexTest = original; store.restore(); }
});

test("conversation initial full-message hydration stays locked and cannot mutate after detachment", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  let finish;
  globalThis.atlasApexTest = async (name) => {
    if (name === "getConversation") return JSON.stringify({id: "one", messages: [{direction: "To Agent", kind: "results", hasFullBody: true}], changes: []});
    if (name === "getState") return JSON.stringify({revision: 1, data: {paste: "Kept"}});
    assert.equal(name, "getMessage"); return new Promise((resolve) => { finish = resolve; });
  };
  try {
    const loading = c.load(true);
    while (!finish) await Promise.resolve();
    assert.equal(c.ready, false); c.disconnectedCallback();
    finish("stale outgoing"); await loading;
    assert.equal(c.outgoing, undefined); assert.equal(c.draftLoaded, false);
  } finally { globalThis.atlasApexTest = original; }
});

test("source review recovers a revision-scoped note but never activation consent", () => {
  const store = browserDraftStore();
  try {
    const change = { id: "change", revision: 3, status: "Proposed", proposal: { files: [] } };
    const c = new components.atlasReview(); c.boot = draftBoot; c.change = change; c.connectedCallback();
    c.handleNote({ detail: { value: "Please preserve the validation rule." } });
    c.handleActivation({ target: { checked: true } });
    const next = new components.atlasReview(); next.boot = draftBoot; next.change = change; next.connectedCallback();
    assert.equal(next.note, c.note); assert.equal(next.activationConfirmed, false);
    next.change = { ...change, revision: 4 };
    assert.equal(next.note, ""); assert.equal(next.activationConfirmed, false);
  } finally { store.restore(); }
});

test("ticket editor recovery preserves unsaved values and the original optimistic version", async () => {
  const c = new components.atlasTickets(), saved = new Map(); recoveryStore(c, saved);
  c.selected = { id: "one", version: "v1" }; c.savedEditing = '{"summary":"Old"}'; c.editing = { summary: "Unsaved", future: { keep: true } };
  c.busy = true; await c.snoozeTomorrow(); assert.equal(c.editing.snooze, undefined); c.busy = false;
  await c.saveAndCloseEditor(); assert.equal(c.selected, null);
  c.recoveryDraft = saved.values().next().value; await c.resumeRecovery();
  assert.equal(c.selected.version, "v1"); assert.equal(c.editing.summary, "Unsaved"); assert.equal(c.editing.future.keep, true); assert.equal(c.editorDirty, true);
});

test("Support Tickets keeps its internal value while showing the exact label and filtering by that label", () => {
  const work = new components.atlasWork();
  const option = work.modeOptions.find((item) => item.value === "support-tickets");
  assert.equal(option.displayLabel, "Support Tickets");
  assert.equal(option.ariaLabel, "Support Tickets: Investigate a production support ticket safely");
  work.form = {mode: "support-tickets", title: "", request: ""};
  work.pages = [{id: "one", mode: "support-tickets", title: "Production login fails", status: "Open", updated: "2026-10-19"}];
  work.boot = {conversations: []}; work.filter = "Support Tickets";
  assert.equal(work.conversations[0].mode, "support-tickets");
  assert.equal(work.conversations[0].modeLabel, "Support Tickets");
  const conversation = new components.atlasConversation(); conversation.convo = {mode: "support-tickets", status: "Open"};
  assert.equal(conversation.modeLabel, "Support Tickets");
  assert.match(conversation.modePill, /atlas-pill_warning/);
});

test("Support Tickets blocks source changes before saving the pasted reply", async () => {
  const c = new components.atlasConversation();
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-1";
  c.paste = JSON.stringify({type: "atlas-change", requestId: "conversation-1", change: "CHG-1"});
  await c.processPaste();
  assert.match(c.problem.text, /Support Tickets cannot process atlas-change/);
  assert.equal(c.outbox, undefined);
  assert.equal(c.busy, false);
});

test("Support Tickets displays a validated report and restores it from conversation history", async () => {
  const report = {
    type: "atlas-support-ticket-report", requestId: "conversation-1", organization: "Production org as reported by the administrator",
    productionFacts: ["The administrator reports that saving a Case fails."], qaEvidence: ["The connected org has an active Case flow."],
    hypotheses: ["Production may have a different flow version."], likelyProblem: "The flow may reject this update.", confidence: "Moderate",
    missingEvidence: ["The production flow version."], recommendedSolution: "Have an administrator compare the production flow before changing it.",
    productionSteps: ["Confirm the production org and the affected Case."], prerequisites: ["Back up the flow."], permissions: ["Salesforce administrator."],
    verification: ["Repeat the update with a test Case."], stopConditions: ["Stop if production differs from the connected org."], rollback: ["Restore the previous flow version if the change fails."], jiraEscalation: null,
  };
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-1";
  c.boot = {org: {name: "Demo", id: "00D", isSandbox: false, edition: "Developer Edition", namespace: "demo"}, people: []};
  c.settings = {jira: {}, mine: {replyLimit: 100000}}; c.connected = true; c.draftLoaded = false;
  c.template = {querySelector: () => ({value: ""})}; c.outbox = {enqueue: async () => {}, flush: async () => {}}; c.load = async () => {};
  c.paste = JSON.stringify(report);
  try {
    await c.processPaste();
    assert.match(c.ticketReport.text, /Connected Salesforce research org: Demo \(00D\)/);
    assert.match(c.ticketReport.text, /1\. Confirm the production org and the affected Case/);
    assert.equal(c.paste, "");

    const restored = new components.atlasConversation();
    restored.conversationId = "conversation-1"; restored.connected = true;
    restored.boot = c.boot; restored.settings = c.settings;
    globalThis.atlasApexTest = async (name) => {
      if (name === "getConversation") return JSON.stringify({id: "conversation-1", mode: "support-tickets", messages: [
        {id: "report", recordId: "report", direction: "From Agent", kind: "atlas-support-ticket-report", body: JSON.stringify(report), hasFullBody: false, created: "2026-10-19"},
      ], changes: []});
      if (name === "getState") return JSON.stringify({revision: 1, data: {}});
      throw Error(`Unexpected ${name}`);
    };
    await restored.load(true);
    assert.match(restored.ticketReport.text, /Evidence observed in the connected Salesforce org/);
  } finally { globalThis.atlasApexTest = original; }
});

test("Support Tickets changes the generated operation ID when the confirmed review manager changes", async () => {
  const c = new components.atlasConversation();
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-1";
  c.boot = {people: [
    {id: "P2", name: "Rob", active: true, jiraId: "acc-rob"},
    {id: "P3", name: "Kim", active: true, jiraId: "acc-kim"},
  ]};
  c.settings = {jira: {projectKey: "ABC", externalCredential: "Configured", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
  const operationIds = [];
  c.reviewJiraWrite = async (request) => { operationIds.push(request.operationId); };
  await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
  c.settings.jira.reviewManagerPersonId = "P3";
  await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
  assert.notEqual(operationIds[0], operationIds[1]);
});

test("Support Tickets creates a replacement only from a fresh, explicitly invalidated receipt and retries it after reload", async () => {
  const originalApex = globalThis.atlasApexTest, originalList = globalThis.atlasListWritesTest;
  const receipts = [], preparedIds = [];
  const panel = () => {
    const c = new components.atlasConversation();
    c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-retry";
    c.boot = {people: [{id: "P2", name: "Rob", active: true, jiraId: "acc-rob"}]};
    c.settings = {mine: {replyLimit: 100000}, jira: {projectKey: "ABC", siteUrl: "https://jira.example", apiBaseUrl: "https://jira.example", namedCredential: "Jira_NC", externalCredential: "Jira_EC", connectionRevision: "revision-1", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
    return c;
  };
  globalThis.atlasListWritesTest = async () => JSON.stringify(receipts);
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "prepareWrite") {
      const request = JSON.parse(args.requestJson);
      preparedIds.push(request.requestId);
      let receipt = receipts.find((row) => row.requestId === request.requestId);
      if (!receipt) {
        receipt = {id: `receipt-${receipts.length + 1}`, requestId: request.requestId, state: "reviewed", operation: "create", message: "Review this exact Jira request. Nothing has been sent."};
        receipts.unshift(receipt);
      }
      return JSON.stringify(receipt);
    }
    if (name === "addMessage") return null;
    throw Error(`Unexpected ${name}`);
  };
  try {
    const first = panel();
    await first.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    const originalId = preparedIds[0];
    receipts[0] = {...receipts[0], state: "invalidated", message: "Jira configuration changed after review. Nothing was sent. Prepare a new review."};
    first.settings.jira.connectionRevision = "revision-2";
    await first.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    const replacementId = preparedIds[1];
    assert.notEqual(replacementId, originalId, "a confirmed invalidation permits a fresh review generation");
    assert.equal(receipts.length, 2);

    const reloaded = panel();
    await reloaded.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    assert.equal(preparedIds[2], replacementId, "the server's saved replacement remains the exact retry identity after reload");
    assert.equal(new Set(preparedIds).size, 2);
    assert.equal(receipts.length, 2, "retries do not create another review");
  } finally { globalThis.atlasApexTest = originalApex; globalThis.atlasListWritesTest = originalList; }
});

test("Support Tickets does not replace a current server receipt after connection settings change", async () => {
  const originalApex = globalThis.atlasApexTest, originalList = globalThis.atlasListWritesTest;
  try {
    for (const state of ["queued", "unknown", "succeeded"]) {
    const receipts = [], preparedIds = [];
    const panel = () => {
      const c = new components.atlasConversation();
      c.convo = {mode: "support-tickets"}; c.conversationId = `conversation-${state}`;
      c.boot = {people: [{id: "P2", name: "Rob", active: true, jiraId: "acc-rob"}]};
      c.settings = {mine: {replyLimit: 100000}, jira: {projectKey: "ABC", siteUrl: "https://jira.example", apiBaseUrl: "https://jira.example", namedCredential: "Jira_NC", externalCredential: "Jira_EC", connectionRevision: "revision-1", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
      return c;
    };
    globalThis.atlasListWritesTest = async () => JSON.stringify(receipts);
    globalThis.atlasApexTest = async (name, args) => {
      if (name === "prepareWrite") {
        const request = JSON.parse(args.requestJson);
        preparedIds.push(request.requestId);
        let receipt = receipts.find((row) => row.requestId === request.requestId);
        if (!receipt) {
          receipt = {id: `receipt-${receipts.length + 1}`, requestId: request.requestId, state: "reviewed", operation: "create", message: "Review this exact Jira request. Nothing has been sent."};
          receipts.unshift(receipt);
        }
        return JSON.stringify(receipt);
      }
      if (name === "addMessage") return null;
      throw Error(`Unexpected ${name}`);
    };
    const c = panel();
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    receipts[0] = {...receipts[0], state: "invalidated", message: "Jira configuration changed after review. Nothing was sent. Prepare a new review."};
    c.settings.jira.connectionRevision = "revision-2";
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    const replacementId = preparedIds[1];
    const active = receipts.find((row) => row.requestId === replacementId);
    active.state = state;
    // Simulate a stale local invalidated receipt and a later connection change. The fresh server list wins.
    c.jiraWrites = [{requestId: preparedIds[0], state: "invalidated", message: "Jira configuration changed after review. Nothing was sent. Prepare a new review."}];
    c.settings.jira.connectionRevision = "revision-3";
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    assert.equal(preparedIds[2], replacementId, `${state} receipt must keep its exact operation ID`);
    assert.equal(new Set(preparedIds).size, 2, `${state} must not create a new operation ID`);
    assert.equal(receipts.length, 2);
    }
  } finally { globalThis.atlasApexTest = originalApex; globalThis.atlasListWritesTest = originalList; }
});

test("Support Tickets does not treat a missing server receipt as proof of invalidation", async () => {
  const originalApex = globalThis.atlasApexTest, originalList = globalThis.atlasListWritesTest;
  const preparedIds = [];
  const c = new components.atlasConversation();
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-missing-receipt";
  c.boot = {people: [{id: "P2", name: "Rob", active: true, jiraId: "acc-rob"}]};
  c.settings = {mine: {replyLimit: 100000}, jira: {projectKey: "ABC", siteUrl: "https://jira.example", apiBaseUrl: "https://jira.example", namedCredential: "Jira_NC", externalCredential: "Jira_EC", connectionRevision: "revision-1", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
  globalThis.atlasListWritesTest = async () => "[]";
  globalThis.atlasApexTest = async (name, args) => {
    if (name === "prepareWrite") { preparedIds.push(JSON.parse(args.requestJson).requestId); return JSON.stringify({id: "receipt", requestId: preparedIds.at(-1), state: "reviewed", operation: "create", message: "Review this exact Jira request."}); }
    if (name === "addMessage") return null;
    throw Error(`Unexpected ${name}`);
  };
  try {
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    c.jiraWrites = [{requestId: preparedIds[0], state: "invalidated", message: "Jira configuration changed after review. Nothing was sent. Prepare a new review."}];
    c.settings.jira.connectionRevision = "revision-2";
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."});
    assert.equal(preparedIds[1], preparedIds[0], "a missing current server receipt cannot authorize a replacement generation");
    assert.equal(new Set(preparedIds).size, 1);
  } finally { globalThis.atlasApexTest = originalApex; globalThis.atlasListWritesTest = originalList; }
});

test("Support Tickets falls back to a local Bug only after known credential-verification rejection", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-1";
  c.boot = {people: [{id: "P2", name: "Rob", active: true, jiraId: "acc-rob"}]};
  c.settings = {jira: {projectKey: "ABC", externalCredential: "Configured", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
  let fallbacks = 0;
  c.checkTickets = async (message) => { fallbacks++; c.ticketReview = {items: message.tickets}; };
  globalThis.atlasApexTest = async (name) => {
    assert.equal(name, "prepareWrite");
    throw {body: {message: "Cannot verify the selected Jira Named Credential endpoint and linked External Credential. Ask your Salesforce administrator to check this connection and your access."}};
  };
  try {
    await c.prepareSupportTicketEscalation({summary: "Save fails", description: "Admin-reported failure; org evidence differs."});
    assert.equal(fallbacks, 1);
    assert.match(c.ticketReview.supportTicketWarning, /local Bug draft/);
    assert.match(c.banner.text, /local Bug draft is ready/);
  } finally { globalThis.atlasApexTest = original; }
});

test("Support Tickets never creates a fallback draft after an unknown Jira preparation outcome", async () => {
  const c = new components.atlasConversation(), original = globalThis.atlasApexTest;
  c.convo = {mode: "support-tickets"}; c.conversationId = "conversation-1";
  c.boot = {people: [{id: "P2", name: "Rob", active: true, jiraId: "acc-rob"}]};
  c.settings = {jira: {projectKey: "ABC", externalCredential: "Configured", writeEnabled: true, apiVersion: "3", reviewManagerPersonId: "P2", reviewManagerIdentityType: "accountId"}};
  let fallbacks = 0;
  c.checkTickets = async () => { fallbacks++; };
  globalThis.atlasApexTest = async () => { throw Error("The response from Salesforce could not be confirmed."); };
  try {
    await assert.rejects(c.prepareSupportTicketEscalation({summary: "Save fails", description: "Evidence."}), /could not be confirmed/);
    assert.equal(fallbacks, 0);
  } finally { globalThis.atlasApexTest = original; }
});
