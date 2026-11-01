import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/", import.meta.url);
const bundled = await build({
  entryPoints: [new URL("lwc/atlasWorkspaceLib/atlasWorkspaceLib.js", root).pathname],
  bundle: true, platform: "node", format: "esm", write: false,
  plugins: [{ name: "workspace-boundaries", setup(b) {
    b.onResolve({ filter: /^@salesforce\/apex\// }, ({ path }) => ({ path, namespace: "apex" }));
    b.onLoad({ filter: /.*/, namespace: "apex" }, ({ path }) => ({ contents: `export default args => globalThis.workspaceApex(${JSON.stringify(path.split(".").at(-1))}, args);` }));
    b.onResolve({ filter: /^c\/atlasStorage$/ }, () => ({ path: new URL("lwc/atlasStorage/atlasStorage.js", root).pathname }));
  } }],
});
const W = await import("data:text/javascript;base64," + Buffer.from(bundled.outputFiles[0].text).toString("base64"));
const file = (id, text, extra = {}) => ({ id, documentId: `doc-${id}`, number: "1", title: "Original", path: "original.txt", description: "kept",
  created: "2026-10-14T00:00:00.000Z", bytes: Buffer.byteLength(text), base64: Buffer.from(text).toString("base64"),
  sha256: createHash("sha256").update(text).digest("hex"), ...extra });
const record = (id, type = "Conversation", values = {}) => ({ id, type: `Atlas_${type}__c`, token: `token-${id}`,
  values: { Name: `Atlas ${id}`, ...values }, links: [], history: [] });
const archive = (records = [], files = []) => ({ type: W.FORMAT, version: 1, scope: { ownership: "current-user", cutoff: "2026-10-15T00:00:00.000Z" },
  schemas: Object.fromEntries(W.TYPES.map((type) => [type, { fields: {}, inaccessibleFields: [] }])), records, files,
  completeness: { complete: true, issues: [] } });
const page = (items, nextCursor = null) => ({ items, nextCursor, hasMore: Boolean(nextCursor) });
const pending = (a) => ({ archive: a, raw: JSON.stringify(a), saved: null });

function exportBoundary(a, overrides = {}) {
  const calls = [];
  function paging(items, cursor) {
    const index = cursor ? items.findIndex((item) => item.Id === cursor) + 1 : 0;
    const result = items.slice(index, index + 50);
    return page(result, index + 50 < items.length ? result.at(-1).Id : null);
  }
  const boundary = {
    beginExport: async () => ({ schemas: a.schemas, scope: a.scope }),
    recordPage: async ({ kind, cursor }) => paging(a.records.filter((r) => r.type === kind).map((r) => ({ Id: r.id })), cursor),
    recordBody: async ({ recordId }) => ({ ...a.records.find((r) => r.id === recordId) }),
    linkPage: async ({ recordId, cursor }) => paging(a.records.find((r) => r.id === recordId).links, cursor),
    historyPage: async ({ recordId, cursor }) => paging(a.records.find((r) => r.id === recordId).history, cursor),
    versionPage: async ({ documentId, cursor }) => paging(a.files.filter((f) => f.documentId === documentId).map((f) => ({ Id: f.id })), cursor),
    fileBody: async ({ versionId }) => {
      const result = a.files.find((f) => f.id === versionId);
      if (!result) throw Error("File not accessible");
      return result;
    },
    ...overrides,
  };
  for (const method of Object.keys(boundary)) {
    const real = boundary[method];
    boundary[method] = async (args) => { calls.push({ method, args }); return real(args); };
  }
  return { boundary, calls };
}

test("keyset traversal handles full and short pages without body aggregation", async () => {
  const ids = [];
  const traversed = await W.walkPages(async ({ cursor }) => cursor ? page([{ Id: "c" }]) : page([{ Id: "a" }, { Id: "b" }], "b"), {}, (r) => ids.push(r.Id));
  assert.deepEqual(ids, ["a", "b", "c"]);
  assert.equal(traversed.size, 3);
});

test("keyset traversal fails closed on duplicate, repeated, oversized and inconsistent pages", async () => {
  for (const response of [page([], "bad"), { items: [], hasMore: true, nextCursor: null }, { items: [], hasMore: false, nextCursor: "bad" },
    page(Array.from({ length: 51 }, (_, i) => ({ Id: String(i) }))), page([{ Id: "same" }, { Id: "same" }])]) {
    await assert.rejects(() => W.walkPages(async () => response, {}, () => {}), /Paging|page|Duplicate/);
  }
  let n = 0;
  await assert.rejects(() => W.walkPages(async () => page([{ Id: String(++n) }], "same"), {}, () => {}), /Repeated/);
  let called = false;
  await assert.rejects(() => W.walkPages(async () => { called = true; }, {}, () => {}, () => true), /cancelled/);
  assert.equal(called, false);
});

test("native export reads four records at a time, keeps their order and loads each shared File once", async () => {
  const records = Array.from({ length: 30 }, (_, n) => record(`c${n}`, "Conversation", { Request_File__c: "shared" }));
  const { boundary, calls } = exportBoundary(archive(records, [file("shared", "one body")]));
  let active = 0, peak = 0;
  const slow = (real) => async (args) => { active++; peak = Math.max(peak, active); await new Promise((r) => setTimeout(r, 2)); try { return await real(args); } finally { active--; } };
  boundary.recordBody = slow(boundary.recordBody);
  boundary.linkPage = slow(boundary.linkPage);
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, true, JSON.stringify(result.archive.completeness.issues));
  assert.deepEqual(result.archive.records.map((r) => r.id), records.map((r) => r.id));
  assert.equal(peak, 4, "Independent record reads overlap, bounded at four.");
  assert.equal(calls.filter((c) => c.method === "fileBody").length, 1);
  assert.equal(calls.filter((c) => c.method === "recordBody").length, 60, "Capture and verification each read every record once.");
});

test("cancelling an export stops starting new record reads", async () => {
  const records = Array.from({ length: 40 }, (_, n) => record(`c${n}`));
  const { boundary, calls } = exportBoundary(archive(records));
  let cancelled = false;
  const real = boundary.recordBody;
  boundary.recordBody = async (args) => { if (calls.filter((c) => c.method === "recordBody").length >= 6) cancelled = true; return real(args); };
  await assert.rejects(() => W.exportWorkspace(() => {}, () => cancelled, boundary), /cancelled/);
  assert.ok(calls.filter((c) => c.method === "recordBody").length < 12, "No new reads start after cancelling.");
});

test("native export walks beyond list caps and retains long text, unknown JSON and all version histories", async () => {
  const records = Array.from({ length: 56 }, (_, n) => record(`c${n}`));
  const unknown = '{ "future":900719925474099312345,"tail":"END" }';
  records[0].values.Request__c = "x".repeat(131000) + "END";
  records[0].values.UI_State__c = unknown;
  records[0].values.Request_File__c = "new";
  records[0].links = [{ Id: "link", ContentDocumentId: "originals" }];
  const files = [file("old", "old full body", { documentId: "bodies" }),
    file("new", "é".repeat(140000) + "END", { documentId: "bodies", number: "2" }),
    file("binary", Buffer.from([0, 255, 1, 2]), { documentId: "originals", path: "original.bin" })];
  const ticket = record("ticket", "Ticket", { Pending_Updates__c: unknown });
  ticket.history = Array.from({ length: 73 }, (_, n) => ({ Id: `h${n}`, Field: "Summary__c", OldValue: `old${n}`, NewValue: `new${n}` }));
  records.push(ticket);
  const { boundary, calls } = exportBoundary(archive(records, files));
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, true);
  assert.equal(result.archive.records.length, 57);
  assert.equal(result.archive.records[0].values.UI_State__c, unknown);
  assert.ok(result.archive.records[0].values.Request__c.endsWith("END"));
  assert.equal(result.archive.records.at(-1).history.length, 73);
  assert.deepEqual(new Set(result.archive.files.map((f) => f.id)), new Set(["old", "new", "binary"]));
  assert.equal(Buffer.from(result.archive.files.find((f) => f.id === "new").base64, "base64").toString(), "é".repeat(140000) + "END");
  assert.ok(calls.filter((c) => c.method === "recordPage" && c.args.cursor).length >= 2, "Enumeration and verification both page");
  assert.ok(calls.every((c) => c.method !== "saveEntry"));
  assert.deepEqual(await W.validateArchive(result.raw), result.archive);
});

test("chunked library export follows private upload parts by immutable IDs", async () => {
  const part = file("part", '{"future":900719925474099312345}');
  const manifest = file("manifest", JSON.stringify({ type: "atlas-chunked", count: 1, chars: part.bytes, bytes: part.bytes,
    parts: { 0: { id: part.id, sha256: part.sha256, chars: part.bytes, bytes: part.bytes } } }));
  const r = record("library", "Library", { Kind__c: "workspace", Data_File__c: manifest.id });
  const { boundary, calls } = exportBoundary(archive([r], [part, manifest]));
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, true);
  assert.equal(result.archive.files.length, 2);
  assert.equal(calls.filter((c) => c.method === "fileBody" && c.args.versionId === "part").length, 1);
  assert.deepEqual(W.recoveryFiles(result.archive, r).map((f) => f.id), ["part", "manifest"]);
});

test("shared attachments are exported once, while every source link is preserved", async () => {
  const records = [record("a"), record("b")];
  for (const r of records) r.links = [{ Id: `l-${r.id}`, ContentDocumentId: "doc-f" }];
  const { boundary, calls } = exportBoundary(archive(records, [file("f", "original")]));
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.files.length, 1);
  assert.equal(calls.filter((c) => c.method === "fileBody").length, 1);
  assert.equal(result.archive.records[1].links[0].Id, "l-b");
});

test("changed records, links and inventories are honestly incomplete, not success", async () => {
  const original = record("r");
  let reads = 0, pages = 0;
  const { boundary } = exportBoundary(archive([original]), {
    recordBody: async () => ({ ...original, token: ++reads > 1 ? "changed" : original.token }),
    recordPage: async ({ kind }) => kind === original.type ? page(++pages > 1 ? [] : [{ Id: original.id }]) : page([]),
  });
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, false);
  assert.match(JSON.stringify(result.archive.completeness.issues), /changed during export/);
  assert.throws(() => W.recoveryFiles(result.archive, original), /omission\/conflict/);
});

test("a link change is detected independently of the record token", async () => {
  const r = record("r"); let reads = 0;
  const { boundary } = exportBoundary(archive([r]), { linkPage: async () => page(++reads > 1 ? [{ Id: "new", ContentDocumentId: "newdoc" }] : []) });
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, false);
  assert.match(result.archive.completeness.issues[0].message, /links changed/);
});

test("missing/oversized Files and denied objects are omissions; unaffected selective recovery remains possible", async () => {
  const r = record("bad", "Message", { Body_File__c: "missing" }), good = record("good");
  const a = archive([r, good]);
  a.schemas.Atlas_Person__c = { error: "No read permission" };
  const { boundary } = exportBoundary(a, { fileBody: async () => { throw Error("File exceeds 1,500,000 bytes"); } });
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.equal(result.archive.completeness.complete, false);
  assert.match(JSON.stringify(result.archive.completeness.issues), /No read permission/);
  assert.throws(() => W.recoveryFiles(result.archive, r), /Missing File/);
  assert.deepEqual(W.recoveryFiles(result.archive, good), []);
});

test("inaccessible field names remain explicit in scope without inventing their values", async () => {
  const a = archive([record("r")]); a.schemas.Atlas_Conversation__c.inaccessibleFields = ["UI_State__c"];
  const { boundary } = exportBoundary(a);
  const result = await W.exportWorkspace(() => {}, () => false, boundary);
  assert.deepEqual(result.archive.schemas.Atlas_Conversation__c.inaccessibleFields, ["UI_State__c"]);
  assert.equal(Object.hasOwn(result.archive.records[0].values, "UI_State__c"), false);
});

test("cancellation never returns a mislabeled complete archive", async () => {
  let cancelled = false;
  const { boundary } = exportBoundary(archive([record("r")]));
  const original = boundary.recordBody;
  boundary.recordBody = async (args) => { const result = await original(args); cancelled = true; return result; };
  await assert.rejects(() => W.exportWorkspace(() => {}, () => cancelled, boundary), /cancelled/);
});

test("archive validation rejects legacy shapes, corrupt Files, duplicates and contradictory completeness", async () => {
  await assert.rejects(() => W.validateArchive('{"taskAtlas":{}}'), /native workspace/);
  const a = archive([record("r")], [file("f", "original")]);
  a.files[0].base64 = Buffer.from("modified").toString("base64");
  await assert.rejects(() => W.validateArchive(JSON.stringify(a)), /integrity/);
  a.files[0] = file("f", "original"); a.files.push(a.files[0]);
  await assert.rejects(() => W.validateArchive(JSON.stringify(a)), /duplicate/);
  a.files.pop(); a.records.push(a.records[0]);
  await assert.rejects(() => W.validateArchive(JSON.stringify(a)), /duplicate/);
  a.records.pop(); a.completeness.issues.push({ message: "omitted" });
  await assert.rejects(() => W.validateArchive(JSON.stringify(a)), /completeness/);
});

test("binary decoding rejects invalid base64 and byte-count mismatches without silent repair", () => {
  assert.throws(() => W.fileBytes({ bytes: 0, base64: "!!" }), /encoding/);
  assert.throws(() => W.fileBytes({ bytes: 9, base64: "YQ==" }), /byte count/);
  assert.deepEqual([...W.fileBytes(file("f", Buffer.from([0, 128, 255])))], [0, 128, 255]);
});

test("the full per-File boundary is verified without recursive decoding or truncation", async () => {
  const value = file("boundary", "z".repeat(1500000));
  assert.equal(W.fileBytes(value).length, 1500000);
  await W.validateArchive(JSON.stringify(archive([], [value])));
  assert.throws(() => W.fileBytes({ ...value, bytes: 1500001 }), /byte count/);
});

test("recovery closure preserves older document versions and dependency order, not just latest", () => {
  const old = file("old", "older", { documentId: "doc", number: "1" });
  const latest = file("latest", "current", { documentId: "doc", number: "2" });
  const r = record("r", "Message", { Body_File__c: "old" });
  assert.deepEqual(W.recoveryFiles(archive([r], [latest, old]), r).map((f) => f.id), ["old", "latest"]);
});

test("missing current library chunks block materialization; partial upload manifests remain history", () => {
  const manifest = file("manifest", JSON.stringify({ type: "atlas-chunked", count: 1, parts: {} }));
  const r = record("r", "Library", { Kind__c: "workspace", Data_File__c: "manifest" });
  const a = archive([r], [manifest]);
  assert.throws(() => W.recoveryFiles(a, r), /missing chunks/);
  r.values.Kind__c = "upload";
  assert.equal(W.recoveryFiles(a, r).length, 1);
});

test("chunk hash mismatches and cycles stop before any recovery writes", () => {
  const part = file("part", "body");
  const manifest = file("manifest", JSON.stringify({ type: "atlas-chunked", count: 1,
    parts: { 0: { id: "part", sha256: "0".repeat(64) } } }));
  const r = record("r", "Library", { Kind__c: "workspace", Data_File__c: "manifest" });
  assert.throws(() => W.recoveryFiles(archive([r], [manifest, part]), r), /mismatched chunk/);
  // A manifest depends on a later version in its own document: both dependency constraints cannot hold.
  const later = file("later", "chunk", { documentId: "d", number: "2" });
  const earlier = file("earlier", JSON.stringify({ type: "atlas-chunked", count: 1,
    parts: { 0: { id: "later", sha256: later.sha256 } } }), { documentId: "d" });
  r.values.Data_File__c = "earlier";
  r.values.Kind__c = "upload";
  assert.throws(() => W.recoveryFiles(archive([r], [earlier, later]), r), /cycle/);
});

test("current library chunk sizes and reconstructed JSON are validated before any write", () => {
  const chunk = file("chunk", '{"raw":"é🐻","future":900719925474099312345}');
  const text = Buffer.from(chunk.base64, "base64").toString();
  const data = { type: "atlas-chunked", count: 1, chars: text.length, bytes: chunk.bytes,
    parts: { 0: { id: "chunk", sha256: chunk.sha256, chars: text.length, bytes: chunk.bytes } } };
  const r = record("r", "Library", { Kind__c: "workspace", Data_File__c: "manifest" });
  const input = () => archive([r], [chunk, file("manifest", JSON.stringify(data))]);
  assert.equal(W.recoveryFiles(input(), r).length, 2);
  data.parts[0].chars++;
  assert.throws(() => W.recoveryFiles(input(), r), /chunk sizes/);
  data.parts[0].chars--;
  data.bytes++;
  assert.throws(() => W.recoveryFiles(input(), r), /total sizes/);
  const invalid = file("manifest", '[]');
  assert.throws(() => W.recoveryFiles(archive([r], [invalid]), r), /JSON object/);
});

test("exact raw source including unknown large numbers is archived once before staging", async () => {
  const p = pending(archive([record("r")]));
  p.raw = p.raw.replace(/}$/, ',"future":900719925474099312345}');
  const calls = [];
  globalThis.workspaceApex = async (method, args) => {
    calls.push({ method, args });
    if (method === "reserveRecovery") return { id: "archive", revision: 0 };
    if (method === "saveEntry") return { id: "archive", versionId: "immutable-source" };
    if (method === "prepareRecord") return { id: "plan" };
    if (method === "reviewRecord") return { id: "plan", versionId: "review-v", digest: "hash", conflicts: [] };
    throw Error(method);
  };
  await W.prepareRecovery(p, "r", {});
  await W.prepareRecovery(p, "r", {});
  assert.equal(calls.filter((c) => c.method === "saveEntry").length, 1);
  assert.equal(calls.filter((c) => c.method === "prepareRecord").length, 1);
  assert.equal(calls[1].args.dataJson, p.raw);
  assert.match(calls[1].args.dataJson, /900719925474099312345/);
  assert.equal(calls[2].args.archiveVersionId, "immutable-source");
  assert.ok(!calls.some((c) => c.method === "applyRecord"));
});

test("shared-workspace scope validates and lost source-save responses reuse the reservation", async () => {
  const a = archive([record("r")]); a.scope.ownership = "accessible-records";
  const p = pending(a);
  assert.equal((await W.validateArchive(p.raw)).scope.ownership, "accessible-records");
  let committed = false; const keys = []; let saves = 0;
  globalThis.workspaceApex = async (method, args) => {
    if (method === "reserveRecovery") {
      keys.push(args.recoveryKey);
      return { id: "source", versionId: committed ? "saved-version" : null };
    }
    if (method === "saveEntry") {
      saves++;
      assert.equal(args.recordId, "source"); assert.equal(args.expectedRevision, 0); assert.equal(args.dataJson, p.raw);
      if (!committed) { committed = true; throw Error("Lost response"); }
      return { id: "source", versionId: "saved-version" };
    }
    throw Error(method);
  };
  await assert.rejects(() => W.preserveArchive(p), /Lost response/);
  await W.preserveArchive(p);
  assert.equal(saves, 2, "Retry validates the exact initial payload without adding a version");
  assert.equal(keys[0], keys[1]);
  assert.equal(p.saved.versionId, "saved-version");
});

test("large native archives use the existing chunk adapter without an eager Apex workspace call", async () => {
  const p = pending(archive([record("r")]));
  p.raw = p.raw.replace(/}$/, ',"unknown":"' + "é".repeat(600000) + '"}');
  const parts = []; let committed = false;
  globalThis.workspaceApex = async (method, args) => {
    if (method === "reserveRecovery") return { id: "source", revision: 0 };
    if (method === "beginUpload") { assert.equal(args.bytes, Buffer.byteLength(p.raw)); return "upload"; }
    if (method === "writePart") { parts[args.index] = args.text; return; }
    if (method === "commitUpload") { committed = true; return { id: "source", versionId: "source-version" }; }
    throw Error(method);
  };
  await W.preserveArchive(p);
  assert.equal(committed, true);
  assert.ok(parts.length > 1);
  assert.equal(parts.join(""), p.raw);
  assert.ok(parts.every((part) => part.length <= 190000));
});

test("lost staging responses retry the same plan; only exact selected file closure is sent", async () => {
  const r = record("r", "Message", { Body_File__c: "f" });
  const p = pending(archive([r, record("other")], [file("f", "complete body"), file("unselected", "private unrelated")]));
  p.saved = { id: "source", versionId: "source-version" };
  let prepared = 0, failed = false; const stages = [];
  const boundary = {
    prepareRecord: async (args) => { prepared++; assert.deepEqual(Object.keys(JSON.parse(args.filesJson)), ["f"]); return { id: "plan" }; },
    stageFile: async (args) => { stages.push(args); if (!failed) { failed = true; throw Error("Lost response"); } },
    reviewRecord: async () => ({ id: "plan", versionId: "review", digest: "hash", conflicts: [] }),
  };
  await assert.rejects(() => W.prepareRecovery(p, "r", {}, () => {}, boundary), /Lost response/);
  await W.prepareRecovery(p, "r", {}, () => {}, boundary);
  assert.equal(prepared, 1);
  assert.deepEqual(stages[0], stages[1]);
});

test("missing attachments fail before archiving or staging a selection", async () => {
  const r = record("r"); r.links.push({ ContentDocumentId: "lost" });
  let called = false; globalThis.workspaceApex = async () => { called = true; };
  await assert.rejects(() => W.prepareRecovery(pending(archive([r])), "r", {}), /Missing attached/);
  assert.equal(called, false);
});

test("apply sends only the reviewed immutable version and digest and blocks unresolved conflicts", async () => {
  const calls = []; globalThis.workspaceApex = async (method, args) => { calls.push({ method, args }); return { recordId: "new", historyId: "plan" }; };
  const review = { id: "plan", versionId: "review-v", digest: "review-digest", conflicts: [], fields: { Name: "untrusted client changes ignored" } };
  await W.applyRecovery(review);
  assert.deepEqual(calls, [{ method: "applyRecord", args: { planId: "plan", reviewedVersionId: "review-v", reviewedDigest: "review-digest" } }]);
  await assert.rejects(() => W.applyRecovery({ ...review, conflicts: ["missing parent"] }), /conflicts/);
  assert.equal(calls.length, 1);
});

test("Apex source invariants: allowlists, user mode, ownership, locks, no update/delete of native data or deployments", async () => {
  const read = await readFile(new URL("classes/Atlas_Workspace.cls", root), "utf8");
  const recovery = await readFile(new URL("classes/Atlas_WorkspaceRecovery.cls", root), "utf8");
  for (const source of [read, recovery]) {
    assert.match(source, /public with sharing class/);
    assert.match(source, /AccessLevel\.USER_MODE/);
    assert.match(source, /WITH USER_MODE/);
    assert.doesNotMatch(source, /\bdelete\s+(?:as\s+user\s+)?\w+\s*;|System\.enqueueJob|Atlas_Changes\.|startDeploy|startRetrieve|HttpRequest|\.abbreviate\(|\.left\(/);
  }
  assert.match(read, /'ownership' => 'accessible-records'/);
  assert.doesNotMatch(read, /OwnerId = :owner/);
  assert.match(read, /Id > :afterId/);
  assert.doesNotMatch(read, /\bOFFSET\b|IsLatest/);
  assert.ok(read.indexOf("meta.ContentSize <= MAX_FILE_BYTES") < read.indexOf("SELECT VersionData"));
  assert.match(recovery, /static final Map<String, String> WRITABLE/);
  assert.doesNotMatch(recovery.split("static final Set<String> FILE_FIELDS")[0], /'Atlas_Change__c'\s*=>/);
  assert.match(recovery, /s\.version\.Id == reviewedVersionId/);
  assert.match(recovery, /digest\(s\.version\.VersionData\) == reviewedDigest/);
  assert.match(recovery, /FOR UPDATE/);
  assert.match(recovery, /Database\.rollback/);
  assert.match(recovery, /beforeReview/);
  assert.match(recovery, /beforeApply/);
  assert.match(recovery, /insert as user record/);
  assert.doesNotMatch(recovery, /(?:update|upsert)\s+(?:as\s+user\s+)?record\b/);
  assert.match(recovery, /originatedHere\.containsAll\(documents\)/);
  assert.match(recovery, /s\.data\.get\('status'\) == 'applied'/);
  assert.match(recovery, /sourceArchiveVersionId/);
});
