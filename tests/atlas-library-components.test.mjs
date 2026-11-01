import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import * as files from "../salesforce/static-src/atlas-files.js";

const root = new URL("../salesforce/force-app/main/default/", import.meta.url);
const path = new URL("lwc/atlasLibrary/atlasLibrary.js", root).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-library-tests-"));
const outfile = join(dir, "component.mjs");
await build({
  entryPoints: [path], bundle: true, platform: "node", format: "esm", outfile,
  plugins: [{ name: "lightning-boundaries", setup(b) {
    b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
    b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
      path === "lwc" ? "export class LightningElement { events = []; dispatchEvent(event) { this.events.push(event); } } export const api = () => {};" :
      path.startsWith("@salesforce/apex/") ? `export default (args) => globalThis.libraryApex(${JSON.stringify(path.split(".").at(-1))}, args);` :
      path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"
    }));
    b.onResolve({ filter: /^c\/atlasStorage$/ }, () => ({path: new URL("lwc/atlasStorage/atlasStorage.js", root).pathname}));
    b.onLoad({ filter: /atlasLibrary\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
  }}],
});
const Component = (await import(outfile)).default;
await rm(dir, { recursive: true });
function component() { const c = new Component(); c.files = files; return c; }
function saved(dataJson = '{"notes":{},"groups":[],"future":900719925474099312345}', kind = "notebook") {
  return { id: "entry1", title: "Library entry", kind, revision: 3, versionId: "version3", dataJson };
}
function page(items = [], nextCursor = null) { return { items, nextCursor, hasMore: Boolean(nextCursor) }; }

test("opening a saved entry captures its ID before the browser clears the click target", async () => {
  const c = component();
  const event = { currentTarget: { dataset: { id: "entry1" } } };
  globalThis.libraryApex = async (method, args) => {
    assert.equal(method, "loadEntry");
    assert.equal(args.recordId, "entry1");
    return saved();
  };
  const opening = c.open(event);
  event.currentTarget = null;
  await opening;
  assert.equal(c.problem, "");
  assert.equal(c.id, "entry1");
  assert.equal(c.isNotebook, true);
});

test("failed save keeps complete edits and loaded revision for conflict recovery", async () => {
  const c = component(); c.adopt(saved());
  c.dataJson = files.patchLibraryJSON(c.dataJson, { projectNotes: "Unsaved" });
  const raw = c.dataJson;
  globalThis.libraryApex = async (method, args) => {
    assert.equal(method, "saveEntry");
    assert.equal(args.expectedRevision, 3);
    assert.equal(args.dataJson, raw);
    throw { body: { message: "Library revision conflict" } };
  };
  await c.save();
  assert.equal(c.problem, "Library revision conflict");
  assert.equal(c.dataJson, raw);
  assert.equal(c.revision, 3);
  assert.equal(c.dirty, true);
  assert.equal(c.busy, false);
});

test("successful saves advance revision while edits arriving during the request remain dirty", async () => {
  const c = component(); c.adopt(saved());
  c.dataJson = '{"projectNotes":"submitted"}';
  globalThis.libraryApex = async (method, args) => {
    if (method === "listEntries") return page();
    c.dataJson = '{"projectNotes":"newer typing"}';
    return { ...saved(), revision: 4, versionId: "version4" };
  };
  await c.save();
  assert.equal(c.revision, 4);
  assert.equal(c.savedJson, '{"projectNotes":"submitted"}');
  assert.equal(c.dataJson, '{"projectNotes":"newer typing"}');
  assert.equal(c.dirty, true);
});

test("workspace import previews before writes and emits raw task handoff only after confirmation", async () => {
  const c = component();
  const raw = '{ "notes":{}, "groups":[], "taskAtlas":{"items":[{"id":"legacy","custom":true}]}, "filesAtlas":{"request":"unfinished"}, "future":900719925474099312345 }';
  const calls = [];
  globalThis.libraryApex = async (method, args) => {
    calls.push({method,args});
    if (method === "reserveRecovery") return {id:"archive1",revision:0};
    return method === "saveEntry" ? {...saved(raw,"workspace"),id:"archive1",revision:1} : page();
  };
  await c.previewImport({ target: { files: [{ size: raw.length, text: async () => raw }] } });
  assert.equal(calls.length, 0);
  assert.equal(c.events.length, 0);
  assert.equal(c.pendingImport.preview.tasks, 1);
  await c.confirmImport();
  assert.equal(calls[0].method, "reserveRecovery");
  assert.equal(calls[1].args.dataJson, raw);
  assert.equal(calls[1].args.kind, "workspace");
  assert.equal(c.events.length, 1);
  const event = c.events[0];
  assert.equal(event.type, "imported");
  assert.equal(event.detail.rawWorkspaceJson, raw);
  assert.deepEqual(event.detail.taskAtlas, { items: [{ id: "legacy", custom: true }] });
  assert.deepEqual(event.detail.areas, { source: true, task: true, files: true });
  assert.equal(event.detail.libraryId, "archive1");
  assert.match(c.message, /host now attempts/);
});

test("selective recovery archives everything but only changes selected areas in target", async () => {
  const c = component();
  const target = '{"notes":{"existing":{}},"taskAtlas":{"items":[]},"filesAtlas":{"request":"current"}}';
  const incoming = '{"notes":{"incoming":{}},"taskAtlas":{"items":[{"id":"legacy"}]},"filesAtlas":{"request":"backup"},"unknown":900719925474099312345}';
  c.adopt(saved(target));
  await c.previewImport({ target: { files: [{ size: incoming.length, text: async () => incoming }] } });
  c.recoverSource = false; c.recoverTask = false; c.recoverFiles = true; c.recoverCurrent = true;
  const calls = [];
  globalThis.libraryApex = async (method, args) => {
    if (method === "listEntries") return page();
    if (method === "reserveRecovery") return {id:"archive1",revision:0};
    calls.push(args);
    return { ...saved(), id: args.recordId || "archive1", kind: args.kind, revision: args.recordId ? 4 : 1 };
  };
  await c.confirmImport();
  assert.equal(calls.length, 2);
  assert.equal(calls[0].dataJson, incoming);
  assert.equal(calls[1].recordId, "entry1");
  assert.equal(calls[1].expectedRevision, 3);
  assert.deepEqual(JSON.parse(calls[1].dataJson), { notes: { existing: {} }, taskAtlas: { items: [] }, filesAtlas: { request: "backup" } });
  assert.equal(c.events[0].detail.areas.task, false);
  assert.equal(c.events[0].detail.recoveredId, "entry1");
});

test("retry after recovery conflict does not duplicate the preserved backup or emit success", async () => {
  const c = component(); c.adopt(saved());
  const raw = '{"notes":{},"future":"untouched"}';
  c.pendingImport = { raw, preview: files.workspacePreview(raw), archive: null };
  c.recoverCurrent = true;
  let archives = 0;
  globalThis.libraryApex = async (method, args) => {
    if (method === "reserveRecovery") {archives++; return {id: "archive1", revision: 0};}
    if (args.recordId === "entry1") throw Error("revision conflict");
    return { ...saved(raw, "workspace"), id: "archive1" };
  };
  await c.confirmImport();
  await c.confirmImport();
  assert.equal(archives, 1);
  assert.equal(c.pendingImport.archive.id, "archive1");
  assert.equal(c.events.length, 0);
  assert.match(c.problem, /conflict/);
});

test("library paging uses the exclusive cursor and history review does not replace the current lock", async () => {
  const c = component(); c.adopt(saved());
  const cursors = [];
  globalThis.libraryApex = async (method, args) => {
    if (method === "loadVersion") return { ...saved(), revision: 9, dataJson: '{"historical":"raw"}' };
    cursors.push(args.cursor);
    return args.cursor ? page([{ id: "entry2" }]) : page([{ id: "entry1" }], "entry1");
  };
  await c.refresh(); await c.more();
  assert.deepEqual(cursors, [null, "entry1"]);
  assert.deepEqual(c.entries.map((e) => e.id), ["entry1", "entry2"]);
  await c.openVersion({ currentTarget: { dataset: { id: "version1" } } });
  assert.equal(c.dataJson, '{"historical":"raw"}');
  assert.equal(c.revision, 3, "Keep the originally loaded revision so intervening saves still conflict");
  assert.equal(c.dirty, true);
});

test("source controls preserve unknown nested values and emit exact {text} context", async () => {
  const c = component(); c.adopt(saved('{"notes":{"A.cls":{"future":900719925474099312345}},"groups":[{"unknown":900719925474099355555}],"brief":{}}'));
  c.notePath = "A.cls"; c.notePurpose = "Purpose"; c.noteText = "Do not lose this";
  await c.applyNote();
  c.featureName = "Feature"; c.featurePaths = "A.cls\nB.cls";
  await c.addFeature();
  c.snippetPath = "A.cls"; c.snippetText = "class A {}";
  await c.addSnippet();
  assert.match(c.dataJson, /900719925474099312345/);
  assert.match(c.dataJson, /900719925474099355555/);
  assert.equal(JSON.parse(c.dataJson).groups.length, 2);
  await c.notebookContext();
  c.handoff();
  assert.equal(c.events[0].type, "context");
  assert.deepEqual(Object.keys(c.events[0].detail), ["text"]);
  assert.match(c.events[0].detail.text, /Do not lose this/);
  assert.match(c.events[0].detail.text, /class A/);
});

test("full export walks every server page and keeps raw payloads intact", async () => {
  const c = component(), exported = [];
  c.download = (name, text) => exported.push({ name, text });
  globalThis.libraryApex = async (method, args) => {
    if (method === "listEntries") return args.cursor ? page([{ id: "two" }]) : page([{ id: "one" }], "one");
    return { ...saved('{"unknown":900719925474099312345}'), id: args.recordId };
  };
  await c.exportAll();
  const result = JSON.parse(exported[0].text);
  assert.deepEqual(result.entries.map((e) => e.id), ["one", "two"]);
  assert.equal(result.entries[1].dataJson, '{"unknown":900719925474099312345}');
  assert.match(c.message, /not an atomic/);
});

test("full export loads four entries at a time and keeps the server order", async () => {
  const c = component(), exported = [], ids = Array.from({ length: 9 }, (_, i) => `e${i}`);
  let active = 0, most = 0;
  c.download = (name, text) => exported.push({ name, text });
  globalThis.libraryApex = async (method, args) => {
    if (method === "listEntries") return page(ids.map((id) => ({ id })));
    active++; most = Math.max(most, active);
    await new Promise((resolve) => setTimeout(resolve, 9 - Number(args.recordId.slice(1))));
    active--;
    return { ...saved(), id: args.recordId };
  };
  await c.exportAll();
  assert.equal(most, 4);
  assert.deepEqual(JSON.parse(exported[0].text).entries.map((e) => e.id), ids);
});

test("repeat export cursor fails explicitly without downloading an incomplete archive", async () => {
  const c = component(); let downloaded = false;
  c.download = () => { downloaded = true; };
  globalThis.libraryApex = async (method) => method === "listEntries" ? page([{ id: "one" }], "same") : saved();
  await c.exportAll();
  assert.match(c.problem, /repeated a cursor/);
  assert.equal(downloaded, false);
});

test("draft handoff preserves raw future fields and does not claim host restoration", async () => {
  const c = component(); c.adopt(saved('{"request":"unfinished","future":900719925474099312345}', "draft"));
  c.restoreDraft();
  assert.equal(c.events[0].type, "draft");
  assert.equal(c.events[0].detail.dataJson, c.dataJson);
  assert.equal(c.events[0].detail.revision, 3);
  assert.match(c.message, /host must confirm/);
});

test("brief editing preserves unknown nested JSON and unapplied forms block navigation", async () => {
  const c = component();
  c.adopt(saved('{"brief":{"purpose":{"text":"old","future":900719925474099312345}},"notes":{}}'));
  c.input({ target: { dataset: { field: "briefText" }, value: "New business purpose" } });
  assert.equal(c.navigationDisabled, true);
  assert.match(c.pendingEditorMessage, /business brief/);
  c.briefChanged({ detail: { value: "testing" } });
  assert.equal(c.briefKey, "purpose");
  let called = false;
  globalThis.libraryApex = async () => { called = true; };
  await c.save();
  assert.equal(called, false);
  assert.match(c.problem, /Apply pending/);
  await c.applyBrief();
  assert.equal(c.pendingEditors.length, 0);
  assert.match(c.dataJson, /900719925474099312345/);
  assert.equal(JSON.parse(c.dataJson).brief.purpose.text, "New business purpose");
});

test("applying a different form cannot overwrite unapplied structured JSON", async () => {
  const c = component();
  c.adopt(saved('{"projectNotes":"saved","notes":{},"brief":{}}'));
  c.fieldKey = "projectNotes"; c.syncField();
  c.input({ target: { dataset: { field: "fieldJson" }, value: '"typed but not applied"' } });
  c.notePath = "classes/Foo.cls";
  await c.applyNote();
  assert.match(c.problem, /Apply the current form edits \(structured JSON\)/);
  assert.equal(c.fieldJson, '"typed but not applied"', "The unapplied buffer is kept.");
  assert.equal(JSON.parse(c.dataJson).notes["classes/Foo.cls"], undefined, "The note was not applied either.");
  for (const action of ["applyBrief", "addFeature", "addSnippet", "applySource"]) {
    await c[action]();
    assert.match(c.problem, /structured JSON/, action);
  }
  c.syncBrief(); c.syncField();
  assert.equal(c.fieldJson, '"typed but not applied"', "Resyncing never replaces a pending editor's text.");
  await c.applyField();
  assert.equal(c.problem, "");
  assert.equal(JSON.parse(c.dataJson).projectNotes, "typed but not applied");
});

test("small extracted documents have an immediately valid selected range", async () => {
  const c = component();
  const doc = await files.readLibraryDocument("tiny.txt", new TextEncoder().encode("one\ntwo"));
  c.adopt(saved(JSON.stringify(doc), "document"));
  assert.equal(c.startLine, 1);
  assert.equal(c.endLine, 2);
  await c.documentContext();
  assert.equal(c.problem, "");
  assert.match(c.contextText, /2 \| two/);
});

test("storage is explicitly bounded, locked, user-mode and versioned; controls are wired", async () => {
  const apex = await readFile(new URL("classes/Atlas_Library.cls", root), "utf8");
  assert.match(apex, /with sharing class/);
  assert.match(apex, /FOR UPDATE/);
  assert.match(apex, /revision != expectedRevision/);
  assert.match(apex, /MAX_JSON_BYTES = 1000000/);
  assert.match(apex, /bytes\.size\(\) > MAX_JSON_BYTES/);
  assert.match(apex, /AccessLevel\.USER_MODE/);
  assert.match(apex, /insert as user file/);
  assert.match(apex, /file\.ContentDocumentId = documentId/);
  assert.match(apex, /Database\.rollback/);
  assert.match(apex, /Database\.releaseSavepoint/);
  assert.doesNotMatch(apex, /\.left\(|\.abbreviate\(|delete\s+as|delete\s+\w+;/);
  const html = await readFile(new URL("lwc/atlasLibrary/atlasLibrary.html", root), "utf8");
  for (const [, method] of html.matchAll(/\son\w+=\{(\w+)\}/g)) assert.equal(typeof Component.prototype[method], "function", method);
});

test("unapplied library forms recover after reload without mutating the saved entry", async () => {
  const original = globalThis.sessionStorage, store = new Map();
  globalThis.sessionStorage = { getItem: (key) => store.get(key) ?? null, setItem: (key, value) => store.set(key, value), removeItem: (key) => store.delete(key) };
  const c = component(); c.boot = { org: { id: "org" }, user: { id: "user" } }; c.recoveryConnected = true; c.adopt(saved());
  try {
    c.input({ target: { dataset: { field: "notePath" }, value: "A.cls" } });
    c.input({ target: { dataset: { field: "noteText" }, value: "Unapplied reasoning" } });
    const next = component(); next.boot = c.boot; next.refresh = () => {}; next.connectedCallback();
    assert.equal(next.noteText, "Unapplied reasoning"); assert.equal(next.notePath, "A.cls");
    assert.deepEqual(next.pendingEditors, ["file note"]); assert.equal(next.dataJson, saved().dataJson);
    assert.equal(next.revision, 3); assert.match(next.recoveryStatus, /Recovery itself applies no Salesforce edits/);
    assert.match(next.recoveryStatus, /Compare the recovered state with the saved entry before saving again/);
    assert.doesNotMatch(next.recoveryStatus, /Salesforce is unchanged/);
    next.disconnectedCallback(); const before = store.get(next.editorKey);
    next.noteText = "Late obsolete change"; next.cacheEditor();
    assert.equal(store.get(next.editorKey), before);
    c.dataJson = c.savedJson; c.pendingEditors = []; c.formRecovery = false; c.cacheEditor();
    assert.equal(store.has(c.editorKey), false, "A clean saved editor clears only its recovery key");
  } finally { globalThis.sessionStorage = original; }
});

test("editor recovery does not claim Salesforce was unchanged after a committed save loses its response", async () => {
  const original = globalThis.sessionStorage, store = new Map();
  globalThis.sessionStorage = {getItem: (key) => store.get(key) ?? null, setItem: (key, value) => store.set(key, value), removeItem: (key) => store.delete(key)};
  try {
    const c = component(); c.boot = {org: {id: "org"}, user: {id: "user"}}; c.recoveryConnected = true; c.adopt(saved());
    c.dataJson = '{"projectNotes":"Committed before the response was lost"}';
    let committed, writes = 0;
    globalThis.libraryApex = async (method, args) => {
      assert.equal(method, "saveEntry"); writes++;
      committed = {...saved(args.dataJson), revision: 4, versionId: "version4"};
      throw Error("Save response lost");
    };
    await c.save();
    assert.match(c.problem, /response lost/);
    const next = component(); next.boot = c.boot; next.refresh = () => {}; next.connectedCallback();
    assert.equal(writes, 1, "Recovery must not repeat the uncertain save");
    assert.equal(committed.revision, 4); assert.equal(next.revision, 3);
    assert.equal(next.dataJson, committed.dataJson); assert.equal(next.dirty, true);
    assert.match(next.recoveryStatus, /Recovery itself applies no Salesforce edits/);
    assert.match(next.recoveryStatus, /Compare the recovered state with the saved entry before saving again/);
    assert.doesNotMatch(next.recoveryStatus, /Salesforce is unchanged/);
  } finally { globalThis.sessionStorage = original; }
});

test("library recovery quota failure is visible and keeps the unsaved forms", () => {
  const original = globalThis.sessionStorage;
  globalThis.sessionStorage = { setItem: () => { throw Error("Quota"); } };
  try {
    const c = component(); c.boot = { org: { id: "org" }, user: { id: "user" } }; c.recoveryConnected = true; c.adopt(saved());
    c.input({ target: { dataset: { field: "noteText" }, value: "Keep" } });
    assert.match(c.recoveryStatus, /NOT saved/); assert.equal(c.noteText, "Keep"); assert.equal(c.navigationDisabled, true);
  } finally { globalThis.sessionStorage = original; }
});

test("clean entry form selections survive reload, hydrate once and reset on adoption/save", async () => {
  const original = globalThis.sessionStorage, store = new Map();
  globalThis.sessionStorage = {getItem: (key) => store.get(key) ?? null, setItem: (key, value) => store.set(key, value), removeItem: (key) => store.delete(key)};
  try {
    const c = component(); c.boot = {org: {id: "org"}, user: {id: "user"}}; c.recoveryConnected = true; c.adopt(saved());
    c.input({target: {dataset: {field: "notePath"}, value: "SelectedOnly.cls"}});
    assert.equal(c.dirty, false); assert.equal(c.pendingEditors.length, 0); assert.equal(c.formRecovery, true);
    const next = component(); next.boot = c.boot; next.refresh = () => {}; next.connectedCallback();
    assert.equal(next.notePath, "SelectedOnly.cls");
    next.notePath = "Newer selection"; next.disconnectedCallback(); next.connectedCallback(); assert.equal(next.notePath, "Newer selection");
    next.adopt(saved()); assert.equal(next.formRecovery, false);
    next.input({target: {dataset: {field: "notePath"}, value: "Other.cls"}}); next.dataJson = '{"changed":true}';
    globalThis.libraryApex = async (method) => method === "listEntries" ? page() : {...saved(), revision: 4};
    await next.save(); assert.equal(next.formRecovery, false); assert.equal(store.has(next.editorKey), false);
  } finally { globalThis.sessionStorage = original; }
});

test("malformed editor recovery is rejected before assigning any cached fields", () => {
  const original = globalThis.sessionStorage;
  try {
    for (const invalid of [{notePath: {}}, {pendingEditors: {}}, {briefEnabled: "yes"}, {revision: []}, {sourceStart: "NaN"}, {dataJson: null}]) {
      globalThis.sessionStorage = {getItem: () => JSON.stringify({version: 1, fields: {title: "Do not adopt", savedTitle: "Old", kind: "notebook", dataJson: "{}", savedJson: "{}", pendingEditors: [], ...invalid}})};
      const c = component(); c.boot = {org: {id: "org"}, user: {id: "user"}}; c.refresh = () => {}; c.connectedCallback();
      assert.equal(c.title, ""); assert.equal(c.kind, ""); assert.match(c.recoveryStatus, /could not be read/);
    }
  } finally { globalThis.sessionStorage = original; }
});

test("document getters reuse one parsed and derived view per exact raw value", () => {
  const c = component(), raw = '{ "sections":[{"id":"s","label":"Text","text":"one\\ntwo\\n"}], "warnings":["kept"], "future":900719925474099312345 }';
  c.adopt(saved(raw, "document"));
  const doc = c.document, sections = c.sections, rows = c.documentSections, warnings = c.warnings;
  for (let i = 0; i < 10; i++) {
    assert.equal(c.document, doc); assert.equal(c.sections, sections); assert.equal(c.documentSections, rows); assert.equal(c.warnings, warnings);
  }
  assert.equal(sections[0].label, "Text (3 lines)"); assert.equal(c.dataJson, raw);
  c.dataJson = '{"sections":[],"notice":"different"}'; assert.notEqual(c.document, doc); assert.deepEqual(c.warnings.map((w) => w.text), ["different"]);
  for (const bad of ["null", "[]", "invalid", '{"sections":[null,{}],"warnings":[null]}']) {
    c.dataJson = bad; assert.deepEqual(c.documentSections, []); assert.deepEqual(c.sections, []); assert.deepEqual(c.warnings, []); assert.equal(c.dataJson, bad);
  }
});

test("static resource bundles locally without writing generated deployment files", async () => {
  const result = await build({ entryPoints: [new URL("../salesforce/static-src/atlas-files.js", import.meta.url).pathname], bundle: true, write: false, format: "iife", globalName: "AtlasFiles", target: "es2022", platform: "browser", minify: true });
  assert.ok(result.outputFiles[0].contents.length < 5 * 1024 * 1024);
});
