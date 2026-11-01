import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/", import.meta.url);
const bundled = await build({
  entryPoints: [new URL("lwc/atlasWorkspace/atlasWorkspace.js", root).pathname],
  bundle: true, platform: "node", format: "esm", write: false,
  plugins: [{ name: "workspace-platform", setup(b) {
    b.onResolve({ filter: /^lwc$|^@salesforce\/apex\// }, ({ path }) => ({ path, namespace: "platform" }));
    b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents: path === "lwc" ?
      "export class LightningElement { events = []; dispatchEvent(event) { this.events.push(event); } }" :
      `export default args => globalThis.workspaceComponentApex(${JSON.stringify(path.split(".").at(-1))}, args);` }));
    b.onResolve({ filter: /^c\/(atlasWorkspaceLib|atlasStorage)$/ }, ({ path }) => ({ path: new URL(`lwc/${path.slice(2)}/${path.slice(2)}.js`, root).pathname }));
  } }],
});
const Component = (await import("data:text/javascript;base64," + Buffer.from(bundled.outputFiles[0].text).toString("base64"))).default;
const makeArchive = (count = 1) => ({ type: "atlas-native-workspace", version: 1, scope: { ownership: "current-user" }, schemas: {},
  records: Array.from({ length: count }, (_, n) => ({ type: "Atlas_Conversation__c", id: `r${n}`, values: { Name: `Atlas Conversation ${n}` }, links: [], history: [] })),
  files: [], completeness: { complete: true, issues: [] } });
const event = (raw) => ({ target: { files: [{ size: Buffer.byteLength(raw), text: async () => raw }] } });
const review = (extra = {}) => ({ id: "plan", versionId: "reviewed-version", digest: "digest", mode: "insert", conflicts: [], notices: [], status: "staging", ...extra });

test("native file preview is local-only and preserves exact raw unknown JSON", async () => {
  const c = new Component(), raw = JSON.stringify(makeArchive()).replace(/}$/, ',"future":900719925474099312345}');
  let calls = 0; globalThis.workspaceComponentApex = async () => { calls++; };
  await c.importFile(event(raw));
  assert.equal(calls, 0);
  assert.equal(c.pending.raw, raw);
  assert.equal(c.review, null);
  assert.match(c.message, /No records or Files were written/);
  assert.equal(c.events.length, 0);
});

test("100 MiB file metadata gate rejects before reading or discarding current archive", async () => {
  const c = new Component(); await c.importFile(event(JSON.stringify(makeArchive())));
  const original = c.pending;
  let read = false;
  await c.importFile({ target: { files: [{ size: 100 * 1024 * 1024 + 1, text: async () => { read = true; } }] } });
  assert.equal(read, false);
  assert.equal(c.pending, original);
  assert.match(c.problem, /100 MiB/);
});

test("legacy raw archives are rejected without changing a valid native selection", async () => {
  const c = new Component(); await c.importFile(event(JSON.stringify(makeArchive())));
  const original = c.pending;
  await c.importFile(event('{"taskAtlas":{"items":[]}}'));
  assert.equal(c.pending, original);
  assert.match(c.problem, /native workspace/);
});

test("selection pages 25 records and never silently auto-selects or applies a batch", async () => {
  const c = new Component(); await c.importFile(event(JSON.stringify(makeArchive(53))));
  assert.equal(c.rows.length, 25);
  assert.equal(c.previousDisabled, true);
  c.next(); assert.equal(c.rows[0].id, "r25"); assert.equal(c.rows.length, 25);
  c.next(); assert.equal(c.rows[0].id, "r50"); assert.equal(c.rows.length, 3);
  assert.equal(c.nextDisabled, true);
  c.previous(); assert.equal(c.rows[0].id, "r25");
  assert.equal(c.review, null);
  assert.equal(c.applyDisabled, true);
});

test("prepare preserves source and obtains a review but does not apply", async () => {
  const c = new Component(); await c.importFile(event(JSON.stringify(makeArchive())));
  const calls = [];
  globalThis.workspaceComponentApex = async (method, args) => {
    calls.push({ method, args });
    if (method === "reserveRecovery") return { id: "source", revision: 0 };
    if (method === "saveEntry") return { id: "source", versionId: "source-v" };
    if (method === "prepareRecord") return { id: "plan" };
    if (method === "reviewRecord") return review();
    throw Error(method);
  };
  await c.prepare({ currentTarget: { dataset: { id: "r0" } } });
  assert.deepEqual(calls.map((c) => c.method), ["reserveRecovery", "saveEntry", "prepareRecord", "reviewRecord"]);
  assert.equal(JSON.parse(calls[2].args.recordJson).id, "r0");
  assert.equal(c.review.versionId, "reviewed-version");
  assert.equal(c.planId, "plan");
  assert.equal(c.applyDisabled, true, "Explicit human acknowledgment is still required");
});

test("confirmation sends pinned review and emits success only after native apply receipt", async () => {
  const c = new Component(); c.review = review();
  const receipt = { recordId: "new-native", historyId: "private-history", sourceId: "old-source", mode: "insert" };
  const calls = [];
  globalThis.workspaceComponentApex = async (method, args) => { calls.push({ method, args }); return receipt; };
  await c.apply(); assert.equal(calls.length, 0);
  c.acknowledge({ target: { checked: true } });
  await c.apply();
  assert.deepEqual(calls[0], { method: "applyRecord", args: { planId: "plan", reviewedVersionId: "reviewed-version", reviewedDigest: "digest" } });
  assert.deepEqual(c.events[0].detail, receipt);
  assert.equal(c.events[0].type, "recovered");
  assert.deepEqual(JSON.parse(c.referenceJson), { "old-source": "new-native" });
  assert.equal(c.applyDisabled, true);
  assert.match(c.message, /Existing records unchanged/);
});

test("lost apply response keeps the exact review for idempotent retry and emits no false success", async () => {
  const c = new Component(); c.review = review(); c.acknowledged = true;
  const sent = []; let fail = true;
  globalThis.workspaceComponentApex = async (method, args) => {
    sent.push(args);
    if (fail) { fail = false; throw { body: { message: "Lost response; outcome not yet known" } }; }
    return { recordId: "same-created-record", historyId: "plan", sourceId: "r0", mode: "insert" };
  };
  await c.apply();
  assert.match(c.problem, /Lost response/);
  assert.equal(c.events.length, 0);
  assert.equal(c.review.versionId, "reviewed-version");
  assert.equal(c.applyDisabled, false);
  await c.apply();
  assert.deepEqual(sent[0], sent[1]);
  assert.equal(c.events.length, 1);
});

test("missing references and existing identity conflicts cannot be approved away", async () => {
  const c = new Component(); c.review = review({ conflicts: ["Missing reference", "Existing unique identity"] }); c.acknowledged = true;
  let called = false; globalThis.workspaceComponentApex = async () => { called = true; };
  assert.equal(c.applyDisabled, true);
  await c.apply(); assert.equal(called, false);
  assert.match(c.reviewSummary, /2 blocking conflict/);
});

test("editing mappings invalidates an earlier approval instead of reusing a stale reviewed version", () => {
  const c = new Component(); c.review = review(); c.acknowledged = true;
  c.input({ target: { dataset: { field: "referenceJson" }, value: '{"old":"new"}' } });
  assert.equal(c.review, null);
  assert.equal(c.acknowledged, false);
  assert.equal(c.applyDisabled, true);
});

test("recovered change history never becomes a native Change reference mapping", async () => {
  const c = new Component(); c.review = review({ mode: "history-only" }); c.acknowledged = true;
  globalThis.workspaceComponentApex = async () => ({ recordId: "private-history", historyId: "private-history", sourceId: "old-change", mode: "history-only" });
  await c.apply();
  assert.equal(c.referenceJson, "{}");
  assert.match(c.message, /inert history only/);
  assert.match(c.message, /no jobs restarted or deployed/);
});

test("saved source opening pins a specific version rather than reading latest", async () => {
  const c = new Component(); c.archiveId = "source"; c.archiveVersionId = "old-version";
  const calls = [];
  globalThis.workspaceComponentApex = async (method, args) => {
    calls.push({ method, args });
    assert.equal(method, "loadVersion");
    return { id: "source", versionId: "latest-version", loadedVersionId: "old-version", dataJson: JSON.stringify(makeArchive()) };
  };
  await c.openSaved();
  assert.equal(calls[0].args.versionId, "old-version");
  assert.equal(c.pending.saved.versionId, "old-version");
  assert.equal(c.review, null);
});

test("resuming a persisted review requires a new acknowledgment and preserves applied receipts", async () => {
  const c = new Component(); c.planId = "plan"; c.acknowledged = true;
  globalThis.workspaceComponentApex = async (method, args) => {
    assert.equal(method, "reviewRecord"); assert.equal(args.planId, "plan");
    return review({ status: "applied", receipt: { recordId: "existing-recovered" } });
  };
  await c.resume();
  assert.equal(c.acknowledged, false);
  assert.equal(c.applyDisabled, true);
  assert.match(c.reviewText, /existing-recovered/);
});

test("all template controls resolve to component methods and expose explicit limitations", async () => {
  const html = await readFile(new URL("lwc/atlasWorkspace/atlasWorkspace.html", root), "utf8");
  for (const [, method] of html.matchAll(/\son\w+=\{(\w+)\}/g)) assert.equal(typeof Component.prototype[method], "function", method);
  assert.match(html, /1,500,000 bytes per File version/);
  assert.match(html, /insert-only/);
  assert.match(html, /not atomic snapshots/);
  assert.match(html, /explicit mapping/);
  assert.match(html, /role="alert"/);
  assert.match(html, /immutable version and digest/);
  for (const bundle of ["atlasWorkspace", "atlasWorkspaceLib"]) {
    const metadata = await readFile(new URL(`lwc/${bundle}/${bundle}.js-meta.xml`, root), "utf8");
    assert.match(metadata, /<masterLabel>Atlas /);
    assert.match(metadata, /<isExposed>false<\/isExposed>/);
  }
});
