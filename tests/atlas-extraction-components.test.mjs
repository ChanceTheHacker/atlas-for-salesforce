import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import * as files from "../salesforce/static-src/atlas-files.js";
import { startDocumentExtraction } from "../salesforce/static-src/atlas-extraction.js";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url);
const dir = await mkdtemp(join(tmpdir(), "atlas-extraction-components-"));
const components = {};
for (const name of ["atlasWork", "atlasLibrary"]) {
  const outfile = join(dir, name + ".mjs");
  await build({
    entryPoints: [new URL(`${name}/${name}.js`, root).pathname], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{ name: "lightning-boundaries", setup(b) {
      b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\/|^c\// }, ({ path }) => ({ path, namespace: "platform" }));
      b.onResolve({ filter: /\/atlasLib\/uat\.js$/, namespace: "platform" }, ({ path }) => ({ path, namespace: "file" }));
      b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
        path === "lwc" ? "export class LightningElement { events=[]; dispatchEvent(e) { this.events.push(e); } } export const api=()=>{};" :
        path.startsWith("@salesforce/apex/") ? "export default (...args)=>globalThis.extractionApex(...args);" :
        path.startsWith("lightning/") ? "export const loadScript=(...args)=>globalThis.extractionLoad(...args);" :
        path === "c/atlasStorage" ? "export const ARCHIVE_LIMIT=100*1024*1024; export const newLibraryIdentity=()=>crypto.randomUUID(); export const readLibrary=(...a)=>globalThis.extractionApex(...a); export const writeLibrary=readLibrary, restoreLibrary=readLibrary; export const inOrder=async(items,limit,work)=>{const out=[]; for (const [i,item] of items.entries()) out.push(await work(item,i)); return out;};" :
        path === "c/atlasLib" ? `export * from ${JSON.stringify(new URL("atlasLib/uat.js", root).pathname)}; export const MODES={Source:'Source'}; export const MODE_LABELS={Source:'Source'}; export const errorMessage=e=>e.message; export const firstPrompt=()=>''; export const downloadFile=()=>{};` :
        `export default ${JSON.stringify(path.endsWith("Atlas_Extract") ? "/Atlas_Extract.js" : "/Atlas_Files.js")};`
      }));
      b.onLoad({ filter: /atlas(Work|Library)\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
    }}],
  });
  components[name] = (await import(outfile)).default;
}
await rm(dir, { recursive: true });
const turn = () => new Promise((resolve) => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
const selection = (...names) => ({ target: { value: "same-file", files: names.map((name) => ({ name, size: 10 })) } });
const doc = (text = "text") => ({ kind: "Text", text, warnings: ["UTF-8 only"] });
const raw = (text = "text") => JSON.stringify({path: "a.txt", state: "readable", kind: "Text", sections: [{id: "body", label: "Text", text}], notice: "UTF-8 only", warnings: ["UTF-8 only"]});
function setup(kind) {
  const jobs = [], writes = [], caches = [];
  const resource = { ...files, startDocumentExtraction(file, options) {
    const job = { ...deferred(), file, options, cancelled: 0, cancel() { this.cancelled++; } };
    jobs.push(job); options.onProgress("Reading file…"); return job;
  }};
  globalThis.window = { AtlasFiles: resource };
  globalThis.extractionLoad = async () => {};
  globalThis.extractionApex = async (...args) => { writes.push(args); return {}; };
  const c = new components[kind]();
  c.template = {querySelector: () => ({appendChild() {}})};
  if (kind === "atlasWork") {
    c.creating = true;
    c.form = {mode: "Source", title: "Unsent", request: "Keep typing"};
    c.attachments = [{key: "accepted", name: "accepted.txt", ...doc("accepted")}];
    c.cacheDraft = () => caches.push(JSON.parse(JSON.stringify(c.attachments)));
  } else {
    c.files = resource;
    c.adopt({id: "old", title: "Saved entry", kind: "document", revision: 7, versionId: "v7", dataJson: raw("accepted")});
  }
  return { c, jobs, writes, caches };
}

test("Work stages the whole selection, keeps ordinary editing live and caches only complete acceptance", async () => {
  const {c, jobs, caches, writes} = setup("atlasWork");
  const event = selection("one.txt", "two.txt");
  const reading = c.handleFiles(event);
  assert.equal(event.target.value, "");
  await turn();
  assert.equal(c.busy, false);
  assert.equal(c.editingLocked, false);
  assert.equal(c.startDisabled, true);
  c.handleField({ target: {name: "request", value: "Typed while parsing"}, detail: {} });
  assert.equal(c.form.request, "Typed while parsing");
  assert.deepEqual(caches[0].map((a) => a.name), ["accepted.txt"]);
  await c.start();
  assert.equal(writes.length, 0, "Cannot start while attachment text is incomplete");
  jobs[0].resolve(doc("first")); await turn();
  assert.equal(c.attachments.length, 1);
  assert.equal(caches.length, 1);
  assert.equal(jobs[1].options.mode, "attachment");
  assert.match(c.extractionProgress, /2\/2 — two.txt/);
  jobs[1].resolve(doc("second")); await reading;
  assert.deepEqual(c.attachments.map((a) => a.name), ["accepted.txt", "one.txt", "two.txt"]);
  assert.equal(caches.length, 2);
  assert.equal(c.extracting, false);
  assert.equal(c.startDisabled, false);
});

test("Work cancellation/failure after one staged file never saves partial output or drops old attachments", async () => {
  for (const failure of ["cancel", "error"]) {
    const {c, jobs, caches} = setup("atlasWork");
    const reading = c.handleFiles(selection("one.txt", "two.txt")); await turn();
    jobs[0].resolve(doc("first")); await turn();
    if (failure === "cancel") c.cancelExtraction(); else jobs[1].reject(Error("timeout"));
    await reading;
    const message = c.extractionProgress;
    jobs[1].options.onProgress("late progress"); jobs[1].resolve(doc("late result")); await turn();
    assert.equal(c.extractionProgress, message);
    assert.equal(c.attachments.length, 1);
    assert.equal(c.attachments[0].text, "accepted");
    assert.equal(caches.length, 0);
    assert.equal(c.extracting, false);
    assert.equal(jobs[1].cancelled, 1);
  }
});

test("new Work selection supersedes pending results and old finally cannot clear new progress", async () => {
  const {c, jobs, caches} = setup("atlasWork");
  const event = selection("same.txt");
  const first = c.handleFiles(event); await turn();
  event.target.value = "same-file";
  const second = c.handleFiles(event); await turn();
  assert.equal(event.target.value, "");
  assert.equal(jobs[0].cancelled, 1);
  jobs[0].resolve(doc("stale")); jobs[0].options.onProgress("stale progress"); await first;
  assert.equal(c.extracting, true);
  assert.match(c.extractionProgress, /Reading file/);
  jobs[1].resolve(doc("current")); await second;
  assert.equal(c.attachments.at(-1).text, "current");
  assert.equal(caches.length, 1);
});

test("Work disconnect/navigation aborts the current job and never accepts its late result", async () => {
  for (const leave of [(c) => c.disconnectedCallback(), (c) => c.cancelNew(), (c) => c.select({preventDefault() {}, currentTarget: {dataset: {id: "next"}}}), (c) => { c.openRequest = {id: "next"}; }]) {
    const {c, jobs, caches} = setup("atlasWork");
    const reading = c.handleFiles(selection("a.txt")); await turn();
    leave(c); await reading;
    jobs[0].resolve(doc("late")); await turn();
    assert.equal(jobs[0].cancelled, 1);
    assert.equal(c.attachments.length, 1);
    assert.equal(caches.length, 0);
  }
});

test("Work cancellation during resource loading settles without starting a worker later", async () => {
  const {c, jobs} = setup("atlasWork"), loading = deferred();
  globalThis.extractionLoad = () => loading.promise;
  const reading = c.handleFiles(selection("a.txt"));
  c.cancelExtraction(); await reading;
  loading.resolve(); await turn();
  assert.equal(jobs.length, 0);
  assert.equal(c.extracting, false);
});

test("Library only adopts a complete extraction, preserving warnings and requiring explicit save", async () => {
  const {c, jobs, writes} = setup("atlasLibrary"), previous = c.dataJson;
  const event = selection("a.txt");
  const reading = c.extractFile(event); await turn();
  assert.equal(event.target.value, "");
  assert.equal(c.dataJson, previous);
  assert.equal(c.showSpinner, false, "A blocking spinner must not cover Cancel extraction");
  assert.equal(c.extractionDisabled, false, "A newer file selection can replace this extraction");
  jobs[0].resolve(raw("new text")); await reading;
  assert.equal(c.title, "a.txt");
  assert.equal(c.id, null);
  assert.equal(c.dirty, true);
  assert.equal(c.document.sections[0].text, "new text");
  assert.equal(c.warnings[0].text, "UTF-8 only");
  assert.match(c.message, /not yet saved/);
  assert.equal(writes.length, 0);
});

test("Library cancel/error/disconnect keeps the selected saved entry and rejects stale progress/results", async () => {
  for (const failure of ["cancel", "error", "disconnect"]) {
    const {c, jobs, writes} = setup("atlasLibrary"), previous = c.dataJson;
    const reading = c.extractFile(selection("a.txt")); await turn();
    if (failure === "cancel") c.cancelExtraction();
    else if (failure === "disconnect") c.disconnectedCallback();
    else jobs[0].reject(Error("background worker blocked"));
    await reading;
    const progress = c.extractionProgress;
    jobs[0].resolve(raw("late")); jobs[0].options.onProgress("late"); await turn();
    assert.equal(c.dataJson, previous);
    assert.equal(c.id, "old"); assert.equal(c.revision, 7);
    assert.equal(c.dirty, false);
    assert.equal(c.extractionProgress, progress);
    assert.equal(c.busy, false);
    assert.equal(c.extracting, false);
    assert.equal(jobs[0].cancelled, 1);
    assert.equal(writes.length, 0);
  }
});

test("Library newer selection wins, including repeat selection of the same file", async () => {
  const {c, jobs} = setup("atlasLibrary");
  const event = selection("same.txt");
  const first = c.extractFile(event); await turn();
  event.target.value = "same-file";
  const second = c.extractFile(event); await turn();
  assert.equal(event.target.value, "");
  jobs[0].resolve(raw("old")); await first;
  assert.equal(c.busy, true); assert.equal(c.extracting, true);
  jobs[1].resolve(raw("new")); await second;
  assert.equal(c.document.sections[0].text, "new");
});

test("Library cancel during dependency loading and size/name guards preserve the old entry", async () => {
  const {c, jobs} = setup("atlasLibrary"), loading = deferred(), previous = c.dataJson;
  c.ensureFiles = () => loading.promise;
  const reading = c.extractFile(selection("a.txt"));
  c.cancelExtraction(); await reading;
  loading.resolve(c.files); await turn();
  assert.equal(jobs.length, 0);
  for (const file of [{name: "big.txt", size: 20 * 1024 * 1024 + 1}, {name: "a".repeat(81), size: 1}]) {
    const event = {target: {files: [file], value: "same-file"}};
    await c.extractFile(event);
    assert.equal(event.target.value, ""); assert.equal(c.dataJson, previous); assert.equal(c.busy, false);
  }
  assert.equal(jobs.length, 0);
});

function mockPlatform() {
  const saved = {window: globalThis.window, document: globalThis.document, FileReader: globalThis.FileReader};
  const frames = [], readers = [], listeners = new Set();
  globalThis.window = {location: {href: "https://atlas.invalid/", origin: "https://atlas.invalid"},
    addEventListener: (type, fn) => listeners.add(fn), removeEventListener: (type, fn) => listeners.delete(fn)};
  globalThis.document = {createElement() {
    const frame = {setAttribute() {}, remove() { this.removed = (this.removed || 0) + 1; }, contentWindow: {postMessage(data) {
      this.sent = data;
      if (data.type === "cancel") for (const fn of [...listeners]) fn({source: this, origin: window.location.origin, data: {...data, type: "stopped"}});
    }}};
    frames.push(frame); return frame;
  }};
  globalThis.FileReader = class {
    constructor() { readers.push(this); }
    readyState = 0;
    readAsArrayBuffer() { this.readyState = 1; }
    abort() { this.aborted = true; this.readyState = 2; }
  };
  const emit = (frame, data, overrides = {}) => {
    const id = new URLSearchParams(new URL(frame.src).hash.slice(1)).get("id");
    for (const fn of [...listeners]) fn({source: frame.contentWindow, origin: window.location.origin, data: {channel: "atlas-extraction-v1", id, ...data}, ...overrides});
  };
  return {frames, readers, listeners, emit, host: {appendChild() {}}, restore() { for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete globalThis[key]; else globalThis[key] = value; } }};
}

test("reader cancellation aborts I/O, removes frame and listeners, and ignores queued completion", async () => {
  const p = mockPlatform();
  try {
    const job = startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl: "/extract", host: p.host});
    const frame = p.frames[0]; p.emit(frame, {type: "ready"});
    const reader = p.readers[0], lateRead = reader.onload, lateMessage = [...p.listeners][0];
    const rejection = assert.rejects(job.promise, {name: "AbortError"});
    job.cancel(); job.cancel(); await rejection;
    lateRead(); lateMessage({});
    assert.equal(reader.aborted, true);
    assert.equal(frame.removed, 1);
    assert.equal(frame.contentWindow.sent.type, "cancel");
    assert.equal(p.listeners.size, 0);
    assert.equal(reader.onload, null);
  } finally { p.restore(); }
});

test("bridge validates exact source, origin, nonce and channel before reading or accepting results", async () => {
  const p = mockPlatform();
  try {
    const job = startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl: "/extract", host: p.host});
    const frame = p.frames[0];
    p.emit(frame, {type: "ready"}, {source: {}});
    p.emit(frame, {type: "ready"}, {origin: "https://other.invalid"});
    p.emit(frame, {type: "ready", id: "wrong"});
    p.emit(frame, {type: "ready", channel: "wrong"});
    assert.equal(p.readers.length, 0);
    p.emit(frame, {type: "ready"}); p.emit(frame, {type: "ready"});
    assert.equal(p.readers.length, 1);
    p.emit(frame, {type: "result", result: 1});
    await assert.rejects(job.promise, /invalid result/);
    assert.equal(frame.removed, 1);
  } finally { p.restore(); }
});

test("startup/read timeout, errors and cancellation clean resources without accepting stale results", async () => {
  const p = mockPlatform();
  try {
    for (const mode of ["startup", "timeout", "read-error", "host-error", "wrong-id"]) {
      const job = startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl: "/extract", host: p.host, timeoutMs: 20});
      const frame = p.frames.at(-1);
      if (mode !== "startup") p.emit(frame, {type: "ready"});
      const reader = mode !== "startup" && p.readers.at(-1);
      if (mode === "read-error") reader.onerror();
      if (mode === "host-error") frame.onerror();
      if (mode === "wrong-id") p.emit(frame, {type: "result", id: "not-this-job", result: "stale"});
      await assert.rejects(job.promise, /timed out|could not be read|unavailable/);
      if (reader) assert.equal(reader.aborted, true);
      assert.equal(frame.removed, 1);
      assert.equal(p.listeners.size, 0);
    }
  } finally { p.restore(); }
});

test("external/blob host URL, missing container and unbounded timeout never read or fall back", async () => {
  const p = mockPlatform();
  try {
    for (const workerUrl of ["https://elsewhere.invalid/extract", "blob:https://atlas.invalid/id"]) {
      await assert.rejects(startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl, host: p.host}).promise, /unavailable/);
    }
    await assert.rejects(startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl: "/extract"}).promise, /unavailable/);
    await assert.rejects(startDocumentExtraction({name: "a.txt", size: 1}, {workerUrl: "/extract", host: p.host, timeoutMs: Infinity}).promise, /timeout must/);
    assert.equal(p.readers.length, 0);
    assert.equal(p.frames.length, 0);
  } finally { p.restore(); }
});

test("extraction controls wire progress and cancellation in both templates", async () => {
  for (const name of ["atlasWork", "atlasLibrary"]) {
    const html = await readFile(new URL(`${name}/${name}.html`, root), "utf8");
    assert.match(html, /label="Cancel extraction" onclick=\{cancelExtraction\}/);
    assert.match(html, /role="status" aria-live="polite">\{extractionProgress\}/);
    assert.equal(typeof components[name].prototype.disconnectedCallback, "function");
  }
});
