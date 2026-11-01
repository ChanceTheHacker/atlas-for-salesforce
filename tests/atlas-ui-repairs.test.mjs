import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-ui-repairs-"));
const components = {};
for (const name of ["atlasChanges", "atlasReview", "atlasTickets", "atlasWork", "atlasLibrary"]) {
  const outfile = join(dir, name + ".mjs");
  await build({ entryPoints: [join(root, name, name + ".js")], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{ name: "platform", setup(b) {
      b.onResolve({filter: /^lwc$|^lightning\/|^@salesforce\//}, ({path}) => ({path, namespace: "platform"}));
      b.onLoad({filter: /.*/, namespace: "platform"}, ({path}) => ({contents: path === "lwc"
        ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};"
        : path.startsWith("@salesforce/apex/") ? `export default args => globalThis.uiRepairApex(${JSON.stringify(path.split(".").at(-1))}, args);`
        : path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"}));
      b.onResolve({filter: /^c\//}, ({path}) => ({path: join(root, path.slice(2), path.slice(2) + ".js")}));
      b.onLoad({filter: /\/atlas[^/]+\/atlas[^/]+\.js$/}, async ({path}) => ({contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js"}));
    }}] });
  components[name] = (await import(outfile)).default;
}
const libfile = join(dir, "lib.mjs");
await build({entryPoints: [join(root, "atlasLib/atlasLib.js")], bundle: true, platform: "node", format: "esm", outfile: libfile});
const lib = await import(libfile);
await rm(dir, {recursive: true});
const click = (id) => ({preventDefault() {}, currentTarget: {dataset: {id}}});
const row = (id, status = "Deployed") => ({id, name: id, status, revision: 1, backupSha256: id, backupUrl: "/file/" + id, found: [{}], requested: []});
const plan = (id, activatesFlow = true) => JSON.stringify({source: {id, name: id, revision: 1, backupSha256: id}, activatesFlow,
  components: [{key: "ApexClass:Foo", component: "ApexClass:Foo", type: "ApexClass", name: "Foo", restoreTo: 1, label: "Original", current: 2,
    undone: [{number: 2, label: "Fix " + id, change: id}], latestId: "V" + id}]});
const expectedFor = (id) => JSON.stringify({revision: 1, backupSha256: id, latest: {"ApexClass:Foo": "V" + id}});
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => {resolve = a; reject = b;}); return {promise, resolve, reject}; };
const ticks = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
function storage() {
  const original = globalThis.sessionStorage, values = new Map();
  globalThis.sessionStorage = {getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: (key) => values.delete(key)};
  return {values, restore: () => {globalThis.sessionStorage = original;}};
}
const boot = {org: {id: "org"}, user: {id: "user"}};

test("stale deployment watcher cannot retarget B's restore or carry its consent across A-B-A", async () => {
  const c = new components.atlasChanges(), pending = deferred(), restores = [];
  c.selected = row("A", "Deploying"); c.load = async () => {};
  globalThis.uiRepairApex = async (name, args) => {
    if (name === "deployStatus") return pending.promise;
    if (name === "restorePlan") return plan(args.sourceChangeId);
    if (name === "startRestore") {restores.push(args); return JSON.stringify(row("R", "Restoring"));}
    assert.equal(name, "getChange"); return JSON.stringify(row(args.changeId));
  };
  const watching = c.watch(); await c.select(click("B")); await c.askRestore(); c.handleActivation({target: {checked: true}});
  pending.resolve(JSON.stringify({done: true, change: row("A"), result: {}})); await watching;
  assert.equal(c.selected.id, "B"); assert.equal(c.confirmRestore, true);
  await c.doRestore(); assert.equal(restores[0].sourceChangeId, "B"); assert.equal(restores[0].activationConfirmed, true);
  assert.equal(restores[0].expectedJson, expectedFor("B")); assert.equal(c.selected.id, "R", "The restore is a new change and is selected");
  await c.select(click("B")); await c.askRestore(); c.handleActivation({target: {checked: true}});
  await c.select(click("A")); await c.select(click("B"));
  await c.doRestore(); assert.equal(restores.length, 1, "A-B-A must not reuse the previous confirmation");
  assert.equal(c.activationConfirmed, false);
});

test("restore sends the reviewed plan and surfaces server conflicts without reusing consent", async () => {
  for (const conflict of ["A changed since you opened the restore confirmation. Reload and review again.",
    "ApexClass Foo has a newer version since you opened the restore confirmation. Reload and review again."]) {
    const c = new components.atlasChanges(), calls = [];
    c.selected = row("A", "Failed"); c.load = async () => {};
    globalThis.uiRepairApex = async (name, args) => {
      calls.push({name, args});
      if (name === "restorePlan") {assert.deepEqual(args, {sourceChangeId: "A", componentsJson: null}); return plan("A");}
      assert.equal(name, "startRestore");
      assert.deepEqual(args, {sourceChangeId: "A", componentsJson: null, testLevel: "Default", activationConfirmed: true, expectedJson: expectedFor("A")});
      throw Error(conflict);
    };
    await c.askRestore(); c.handleActivation({target: {checked: true}});
    assert.equal(c.restoreHeading, "Restore the backup?");
    assert.equal(c.restoreItems[0].text, "Back to v1 (Original), replacing v2 Fix A.");
    await c.doRestore();
    assert.match(c.error, /Reload and review again/); assert.equal(calls.filter((r) => r.name === "startRestore").length, 1);
    assert.equal(c.selected.id, "A"); assert.equal(c.selected.revision, 1);
    assert.equal(c.confirmRestore, false); assert.equal(c.activationConfirmed, false);
    await c.doRestore(); assert.equal(calls.filter((r) => r.name === "startRestore").length, 1, "A rejected confirmation requires a fresh review");
  }
});

test("a change whose files were removed offers no restore", async () => {
  const c = new components.atlasChanges(); let calls = 0;
  globalThis.uiRepairApex = async () => {calls++;};
  c.selected = {...row("A"), backupUrl: null, filesRemoved: "2026-10-01T00:00:00.000Z"};
  assert.equal(c.canRestore, false); await c.askRestore(); assert.equal(calls, 0);
  assert.match(c.filesRemovedNote, /removed to free storage/);
});

test("selection fetches, final watcher fetches and failures are scoped to selection epochs", async () => {
  for (const phase of ["select", "watch-status", "watch-fetch"]) for (const end of ["select", "close", "disconnect"]) for (const fail of [false, true]) {
    const c = new components.atlasChanges(), pending = deferred(); c.load = async () => {};
    let delayed = true;
    globalThis.uiRepairApex = async (name, args) => {
      if (delayed && ((phase === "watch-status" && name === "deployStatus") || (phase !== "watch-status" && name === "getChange"))) return pending.promise;
      if (name === "deployStatus") return JSON.stringify({done: true, change: row("A"), result: {}});
      return JSON.stringify(row(args.changeId));
    };
    c.selected = row("A", "Deploying");
    const work = phase === "select" ? c.select(click("A")) : c.watch(); await ticks(); delayed = false;
    if (end === "select") {await c.select(click("B")); await c.select(click("A"));}
    else if (end === "close") c.close(); else c.disconnectedCallback();
    const selected = c.selected, error = c.error;
    if (fail) pending.reject(Error("obsolete failure")); else pending.resolve(JSON.stringify(phase === "watch-status" ? {done: true, change: row("A"), result: {}} : row("A", "Failed")));
    await work;
    assert.equal(c.selected, selected, `${phase}/${end}/${fail}`); assert.equal(c.error, error, `${phase}/${end}/${fail}`);
  }
});

test("restore and reconcile pin request and follow-up fetch to their original selection", async () => {
  for (const action of ["restore", "reconcile"]) for (const fail of [false, true]) {
    const c = new components.atlasChanges(), pending = deferred(), calls = []; c.load = async () => {};
    c.selected = row("A"); c.selected.result = {outcomeUnknown: true}; c.deploymentId = "0Af000000000001";
    let delayed = true;
    globalThis.uiRepairApex = async (name, args) => {
      calls.push({name, args});
      if (name === "restorePlan") return plan(args.sourceChangeId);
      if (delayed && name === (action === "restore" ? "startRestore" : "reconcileDeployment")) return pending.promise;
      return JSON.stringify(row(args.changeId));
    };
    await c.askRestore(); c.handleActivation({target: {checked: true}});
    const work = action === "restore" ? c.doRestore() : c.reconcile(); await ticks(); delayed = false;
    await c.select(click("B")); await c.askRestore();
    const error = c.error;
    if (fail) pending.reject(Error("obsolete action failure")); else pending.resolve(JSON.stringify(row(action === "restore" ? "R" : "A", "Restoring")));
    await work;
    assert.equal(c.selected.id, "B"); assert.equal(c.confirmRestore, true); assert.equal(c.activationConfirmed, false); assert.equal(c.error, error);
    assert.ok(calls.filter((r) => r.name === "startRestore" || r.name === "reconcileDeployment").every((r) => (r.args.sourceChangeId ?? r.args.changeId) === "A"));
  }
});

test("component history restores a chosen version as a new change", async () => {
  const c = new components.atlasChanges(), calls = []; c.load = async () => {};
  globalThis.uiRepairApex = async (name, args) => {
    calls.push({name, args});
    if (name === "componentIndex") return JSON.stringify({complete: true, components: [{key: "ApexClass:Foo", type: "ApexClass", name: "Foo", versions: 3, latest: "Third", change: "C3", at: "2026-10-01T00:00:00.000Z"}]});
    if (name === "componentHistory") return JSON.stringify({component: "ApexClass:Foo", versions: [
      {number: 3, current: true, label: "Third", kind: "Change", change: "C3"},
      {number: 2, current: false, label: "Second", kind: "Change", change: "C2", sourceId: "C3", restorable: true},
      {number: 1, current: false, label: "Original", sourceId: "C2", restorable: false, note: "Backup removed to free storage"}]});
    if (name === "restorePlan") return JSON.stringify({source: {id: "C3", revision: 1, backupSha256: "S"}, activatesFlow: false,
      components: [{key: "ApexClass:Foo", component: "ApexClass:Foo", type: "ApexClass", name: "Foo", restoreTo: 2, label: "Second", current: 3, undone: [{number: 3, label: "Third"}], latestId: "V3"}]});
    if (name === "startRestore") return JSON.stringify({...row("R", "Restoring"), summary: "Restore ApexClass Foo to v2 (Second)"});
    if (name === "deployStatus") return JSON.stringify({done: true, change: row("R", "Restored"), result: {}});
    return JSON.stringify(row(args.changeId, "Restored"));
  };
  c.handleView({detail: {value: "history"}}); await ticks();
  assert.equal(c.showHistory, true); assert.equal(c.componentRows[0].title, "ApexClass Foo");
  await c.openHistory({preventDefault() {}, currentTarget: {dataset: {key: "ApexClass:Foo"}}});
  assert.equal(c.historyTitle, "ApexClass Foo");
  assert.deepEqual(c.versionRows.map((v) => [v.title, v.canRestore, v.restoreLabel]), [["v3", false, "Restore v3"], ["v2", true, "Restore v2"], ["v1", false, "Restore v1"]]);
  assert.equal(c.versionRows[2].note, "Backup removed to free storage");
  await c.restoreVersion({currentTarget: {dataset: {source: "C3"}}});
  assert.deepEqual(calls.find((r) => r.name === "restorePlan").args, {sourceChangeId: "C3", componentsJson: '[{"type":"ApexClass","name":"Foo"}]'});
  assert.equal(c.restoreHeading, "Restore ApexClass Foo to v2?");
  assert.equal(c.restoreItems[0].text, "Back to v2 (Second), replacing v3 Third.");
  assert.equal(c.restoreActivatesFlow, false);
  await c.doRestore();
  assert.deepEqual(calls.find((r) => r.name === "startRestore").args, {sourceChangeId: "C3", componentsJson: '[{"type":"ApexClass","name":"Foo"}]',
    testLevel: "Default", activationConfirmed: false, expectedJson: '{"revision":1,"backupSha256":"S","latest":{"ApexClass:Foo":"V3"}}'});
  assert.equal(c.showChanges, true); assert.equal(c.selected.id, "R");
  await ticks(); await ticks();
  assert.ok(calls.some((r) => r.name === "deployStatus" && r.args.changeId === "R"), "The new restore is followed until it finishes");
});

test("freeing storage removes exactly the reviewed changes", async () => {
  const c = new components.atlasChanges(), calls = []; c.load = async () => {calls.push({name: "load"});};
  let removable = {changes: 2, ids: ["X", "Y"], files: 3, bytes: 2048, restorePoints: 1, names: ["C1", "C2"], more: 0};
  globalThis.uiRepairApex = async (name, args) => {
    calls.push({name, args});
    if (name === "storagePlan") return JSON.stringify({...removable, days: args.olderThanDays});
    assert.equal(name, "freeStorage"); return JSON.stringify({changes: 2, files: 3, failed: 0, bytes: 2048});
  };
  c.toggleStorage(); await ticks();
  assert.equal(c.storageSummary, "2 change(s) older than 90 days have 3 file(s), 2.0 KB. Removing them takes away 1 restore point(s).");
  assert.equal(c.storageNames, "C1, C2"); assert.equal(c.freeDisabled, false);
  c.handleStorageDays({detail: {value: "365"}}); await ticks();
  await c.freeUp();
  assert.deepEqual(calls.find((r) => r.name === "freeStorage").args, {olderThanDays: 365, expectedJson: '["X","Y"]'});
  assert.equal(c.storageDone, "Removed 3 file(s) from 2 change(s), freeing 2.0 KB."); assert.equal(c.freeDisabled, true);
  assert.ok(calls.some((r) => r.name === "load"));
  removable = {changes: 0, ids: [], files: 0, bytes: 0, restorePoints: 0, names: [], more: 0};
  c.toggleStorage(); c.toggleStorage(); await ticks();
  assert.equal(c.storageSummary, "Nothing older than 365 days can be removed."); assert.equal(c.storageDone, "");
  await c.freeUp(); assert.equal(calls.filter((r) => r.name === "freeStorage").length, 1);
});

test("review trusts the server DOM activation flag instead of a second regex parser", () => {
  const c = new components.atlasReview();
  const xml = '<md:Flow xmlns:md="http://soap.sforce.com/2006/04/metadata"><md:status><![CDATA[Active]]></md:status></md:Flow>';
  c.change = {...row("A", "Proposed"), activatesFlow: true, proposal: {files: [{path: "flows/X.flow", content: xml}]}};
  assert.equal(c.activatesFlow, true); assert.equal(c.approvalDisabled, true);
  c.handleActivation({target: {checked: true}}); assert.equal(c.approvalDisabled, false);
  c.change = {...c.change, revision: 2, activatesFlow: false, proposal: {files: [{path: "flows/X.flow", content: '<Flow><description>&lt;status&gt;Active&lt;/status&gt;</description></Flow>'}]}};
  assert.equal(c.activatesFlow, false); assert.equal(c.activationConfirmed, false);
});

test("manual parent transitions survive save/reload and export as one exclusive parent state", async () => {
  const c = new components.atlasTickets(); c.scheduleRecovery = () => {}; c.load = async () => {};
  let ticket = {id: "child", summary: "Child", version: "v1", issueType: "Task", epicId: "epic", epicKey: "DEMO-1"};
  globalThis.uiRepairApex = async (name, args) => {
    if (name === "getTicket") return ticket;
    if (name === "ticketFiles") return JSON.stringify({files: [], nextCursor: null});
    assert.equal(name, "saveTicket"); ticket = {...ticket, ...JSON.parse(args.ticketJson)};
  };
  for (const [field, value, id, key] of [["epicKey", " other-2 ", "", "OTHER-2"], ["epicId", "epic2", "epic2", ""], ["epicId", "", "", ""]]) {
    await c.fetchTicket("child");
    c.handleEdit({target: {name: field}, detail: {value}}); await c.saveSelected(); await c.fetchTicket("child");
    assert.equal(ticket.epicId, id); assert.equal(ticket.epicKey, key); assert.equal(c.editing.epicId, id); assert.equal(c.editing.epicKey, key);
    const result = lib.exportCSV([ticket, {id: "epic2", issueType: "Epic", summary: "Epic", jiraKey: "DEMO-3"}]);
    assert.equal(result.rows[0][result.headers.indexOf("Epic Link")], id ? "DEMO-3" : key);
  }
});

test("Jira actionable copy includes pending parts only and terminal updates offer no actions", async () => {
  const update = {id: "u", status: "pending", changes: {summary: "kept", priority: "skip", dueDate: "2026-10-20", assigneeId: "person"}, assigneeLabel: "Assigned", fieldStatus: {summary: "done", priority: "dismissed", assigneeId: "done"}, comments: [{text: "posted", status: "done"}, {text: "skip comment", status: "dismissed"}, {text: "remaining", mentions: [{alias: "teammate"}]}]};
  const text = lib.updateText(update);
  assert.match(text, /dueDate: 2026-10-20/); assert.match(text, /remaining/); assert.match(text, /teammate/);
  for (const completed of ["kept", "skip", "Assigned", "posted"]) assert.ok(!text.includes(completed));
  for (const status of ["done", "dismissed"]) assert.equal(lib.updateText({...update, status}), "");
  const c = new components.atlasTickets();
  globalThis.uiRepairApex = async (name) => name === "getTicket" ? {id: "ticket", pendingUpdates: [{...update, status: "done"}]} : JSON.stringify({files: []});
  await c.fetchTicket("ticket");
  assert.equal(c.selected.updates[0].pending, false); assert.ok(c.selected.updates[0].parts.every((part) => part.finished));
  const html = await readFile(join(root, "atlasTickets/atlasTickets.html"), "utf8");
  assert.match(html, /<template lwc:if=\{u\.pending\}>\s*<c-atlas-copy/);
});

test("stored null/empty assignment changes explicitly instruct unassignment; named assignment remains clear", () => {
  const people = [{id: "person", name: "Teammate", jiraId: "jira-account", aliases: ["teammate"]}];
  for (const assignee of [null, "", "teammate"]) {
    const checked = lib.checkTicketBatch({updates: [{target: "DEMO-1", changes: {assignee}}]}, {people});
    assert.deepEqual(checked.errors, []);
    const changes = {...checked.batch.updates[0].changes}, assigneeLabel = changes.assignee;
    delete changes.assignee; // Atlas_Tickets.queueUpdates' stored shape.
    const text = lib.updateText({status: "pending", changes, assigneeLabel});
    assert.match(text, assignee ? /assignee:.*Teammate|assignee:.*jira-account/i : /assignee:.*unassign/i);
  }
  for (const changes of [{assigneeId: null}, {assigneeId: ""}, {assignee: null}, {assignee: ""}]) {
    assert.match(lib.updateText({status: "pending", changes, assigneeLabel: null}), /assignee:.*unassign/i);
    assert.equal(lib.updateText({status: "pending", changes, fieldStatus: Object.fromEntries(Object.keys(changes).map((key) => [key, "done"]))}), "");
  }
  assert.match(lib.updateText({changes: {assigneeId: "person"}, assigneeLabel: "Teammate (jira-account)"}), /assignee: Teammate \(jira-account\)/);
});

// Simulate the existing reserveRecovery + saveEntry revision contract, including a
// write that committed even though the caller never received its response.
function libraryServer(failure) {
  const entries = new Map(); let failed = false;
  return {entries, async call(name, args) {
    if (name === "listEntries") return {items: [], nextCursor: null};
    if (name === "reserveRecovery") {
      if (!entries.has(args.recoveryKey)) entries.set(args.recoveryKey, {id: `entry-${entries.size}`, revision: 0, versions: 0});
      const row = entries.get(args.recoveryKey);
      if (failure === "reserve" && !failed) {failed = true; throw Error("lost reservation response");}
      return {...row};
    }
    assert.equal(name, "saveEntry");
    let row = [...entries.values()].find((r) => r.id === args.recordId);
    if (!row) {row = {id: `duplicate-${entries.size}`, revision: 0, versions: 0}; entries.set(row.id, row);}
    if (row.revision !== args.expectedRevision) {
      if (row.revision === args.expectedRevision + 1 && row.dataJson === args.dataJson && row.title === args.title) return {...row};
      throw Error("Library revision conflict");
    }
    Object.assign(row, {dataJson: args.dataJson, title: args.title, kind: args.kind, revision: row.revision + 1, versionId: "version"}); row.versions++;
    if (failure === "commit" && !failed) {failed = true; throw Error("lost commit response");}
    return {...row};
  }};
}

test("new Library small saves reuse a pre-network identity across lost reservation/commit and reload", async () => {
  for (const failure of ["reserve", "commit"]) {
    const store = storage(), server = libraryServer(failure);
    globalThis.uiRepairApex = (name, args) => {
      const cached = JSON.parse(store.values.get(`atlas-library-editor:org:user`) || "null");
      if (name !== "listEntries") assert.ok(cached?.fields.creationKey, "Persist identity before the first write");
      return server.call(name, args);
    };
    try {
      const c = new components.atlasLibrary(); c.boot = boot; c.recoveryConnected = true; c.files = {checkLibraryJSON() {}};
      c.adopt({id: null, kind: "notebook", title: "New", revision: 0, dataJson: '{"notes":{}}'}); c.savedJson = ""; c.savedTitle = "";
      await c.save(); assert.match(c.problem, /lost/);
      const next = new components.atlasLibrary(); next.boot = boot; next.files = c.files; next.refresh = () => {}; next.connectedCallback();
      await next.save(); assert.equal(next.problem, ""); assert.equal(server.entries.size, 1); assert.equal([...server.entries.values()][0].versions, 1);
    } finally {store.restore();}
  }
});

test("Work private drafts reuse exact uncertain saves after reload without swallowing changed content", async () => {
  for (const failure of ["reserve", "commit"]) {
    const store = storage(), server = libraryServer(failure);
    globalThis.uiRepairApex = (name, args) => {
      const cached = JSON.parse(store.values.get("atlas-new:org:user") || "null");
      assert.ok(cached?.libraryDraft?.creationKey, "Persist the private draft's identity before reserving it");
      return server.call(name, args);
    };
    try {
      const c = new components.atlasWork(); c.boot = boot; c.connected = true; c.form = {mode: "Task", title: "Private", request: "Keep"};
      await c.saveDraft(); assert.match(c.error, /lost/);
      const next = new components.atlasWork(); next.boot = boot; next.loadPage = () => {}; next.connectedCallback();
      await next.saveDraft(); assert.equal(server.entries.size, 1); assert.equal([...server.entries.values()][0].versions, 1);
      next.handleField({target: {name: "request"}, detail: {value: "Changed"}}); await next.saveDraft();
      assert.equal(server.entries.size, 2); assert.ok([...server.entries.values()].some((r) => JSON.parse(r.dataJson).request === "Changed"));
    } finally {store.restore();}
  }
});

test("new Library identities never merge intentional equal entries or swallow changes after uncertain commit", async () => {
  const store = storage(), server = libraryServer("commit"); globalThis.uiRepairApex = (name, args) => server.call(name, args);
  const create = () => {
    const c = new components.atlasLibrary(); c.boot = boot; c.recoveryConnected = true; c.files = {checkLibraryJSON() {}};
    c.adopt({id: null, kind: "notebook", title: "Same title", revision: 0, dataJson: '{"value":"original"}'}); c.savedJson = ""; c.savedTitle = ""; return c;
  };
  try {
    const c = create(); await c.save(); assert.match(c.problem, /lost/);
    c.dataJson = '{"value":"changed"}'; await c.save(); assert.match(c.problem, /revision conflict/);
    assert.equal(c.dirty, true); assert.equal(c.dataJson, '{"value":"changed"}'); assert.equal(server.entries.size, 1);
    c.dataJson = '{"value":"original"}'; await c.save(); assert.equal(c.problem, "");
    const other = create(); await other.save(); assert.equal(other.problem, ""); assert.equal(server.entries.size, 2);
    assert.notEqual(c.id, other.id); assert.ok([...server.entries.values()].every((r) => r.versions === 1));
  } finally {store.restore();}
});

test("new small Library and Work saves fail before any write when creation identity cannot persist", async () => {
  const original = globalThis.sessionStorage;
  globalThis.sessionStorage = {setItem() {throw Error("quota");}, getItem() {return null;}};
  let writes = 0; globalThis.uiRepairApex = async () => {writes++;};
  try {
    const c = new components.atlasLibrary(); c.boot = boot; c.recoveryConnected = true; c.files = {checkLibraryJSON() {}};
    c.adopt({id: null, kind: "notebook", title: "Keep", revision: 0, dataJson: "{}"}); c.savedJson = "";
    await c.save(); assert.match(c.problem, /identity could not be saved/); assert.equal(c.dataJson, "{}");
    const work = new components.atlasWork(); work.boot = boot; work.connected = true; work.form.title = "Keep";
    await work.saveDraft(); assert.match(work.error, /identity could not be saved/); assert.equal(work.form.title, "Keep");
    assert.equal(writes, 0);
  } finally {globalThis.sessionStorage = original;}
});

test("the full change DTO derives activation from the existing strict server parser", async () => {
  const apex = await readFile(new URL("../salesforce/force-app/main/default/classes/Atlas_Changes.cls", import.meta.url), "utf8");
  assert.match(apex, /out\.put\('activatesFlow', activates\(proposal\)\)/);
  assert.match(apex, /if \(activates\(proposal\) && !activationConfirmed\) throw/);
  const parser = apex.slice(apex.indexOf("static Boolean activates("), apex.indexOf("static String decideInternal("));
  assert.match(parser, /XmlStreamReader reader = new XmlStreamReader\(/);
  assert.match(parser, /depth == 2 && MD_NS\.equals\(reader\.getNamespace\(\)\)/);
  assert.match(parser, /name\.equals\('status'\) \|\| name\.equals\('activeVersionNumber'\)/);
  for (const event of ["CHARACTERS", "CDATA", "SPACE", "ENTITY_REFERENCE"]) assert.ok(parser.includes(`event == XmlTag.${event}`));
  assert.match(parser, /value \+= reader\.getText\(\)/);
  assert.match(parser, /if \(depth == 2 && activationElement != null\)/);
  assert.match(parser, /Flow activation fields must contain text only/);
  assert.match(parser, /while \(reader\.hasNext\(\)\)/);
  assert.ok(parser.indexOf("if (activation) return true") > parser.indexOf("reader.next()"), "Finish parsing the file before returning activation");
  assert.doesNotMatch(parser, /getNamespaceURI\(|getElementText\(|Dom\.|unescapeXml\(|Pattern\.|\.replace\(/);
});

test("CDATA restore regression reaches parsing with each real backup's matching snapshot", async () => {
  const tests = await readFile(new URL("../salesforce/force-app/main/default/classes/Atlas_ChangesTest.cls", import.meta.url), "utf8");
  const regression = tests.slice(tests.indexOf("static void restoringCdataAndEntityActivationRequiresConfirmation()"), tests.indexOf("static void startsBackupForNewChange()"));
  assert.match(regression, /for \(String xml : activeFlowXml\(\)\)/);
  assert.match(regression, /String backupHash = Atlas_Api\.sha256\(backup\.VersionData\)/);
  assert.match(regression, /Backup_Sha256__c = backupHash/);
  assert.match(regression, /startRestore\(change\.Id, null, 'Default', false, expected\)/);
  assert.match(regression, /'backupSha256' => backupHash/);
  assert.match(regression, /contains\('The backup activates a Flow\.'\)/);
  assert.match(regression, /System\.assertEquals\(0, Limits\.getQueueableJobs\(\)/);
  assert.doesNotMatch(regression, /Atlas_Changes\.restore(?:Confirmed|SnapshotConfirmed)?\(/);
});
