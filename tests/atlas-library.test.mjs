import test from "node:test";
import assert from "node:assert/strict";
import * as L from "../salesforce/static-src/atlas-files.js";

const backup = '{\n"version":4,"notes":{"A.cls":{"notes":"keep me","future":900719925474099312345}},"groups":[],"taskAtlas":{"items":[{"id":"t1","unknown":{"n":900719925474099312345}}]},"filesAtlas":{"request":"draft","history":[{"custom":true}]},"future":{"n":900719925474099312345,"s":"} \\\" , ["},"__proto__":{"notPollution":true}\n}';

test("workspace preview retains the complete raw archive and unknown keys", () => {
  const preview = L.workspacePreview(backup);
  assert.equal(preview.tasks, 1);
  assert.equal(preview.sourceNotes, 1);
  assert.equal(preview.filesHistory, 1);
  assert.ok(preview.keys.includes("future"));
  assert.equal(preview.bytes, new TextEncoder().encode(backup).length);
  assert.equal(L.jsonFields(backup).get("future"), '{"n":900719925474099312345,"s":"} \\\" , ["}');
});

test("source/task/files selective recovery preserves all unselected and unknown raw JSON", () => {
  const target = '{"notes":{"old":{}},"taskAtlas":{"items":[]},"filesAtlas":{"request":"current"},"other":900719925474099399999}';
  const source = L.recoverWorkspace(target, backup, { source: true });
  assert.equal(JSON.parse(source).taskAtlas.items.length, 0);
  assert.equal(JSON.parse(source).filesAtlas.request, "current");
  assert.match(source, /900719925474099312345/);
  assert.match(source, /"other": 900719925474099399999/);
  assert.equal({}.notPollution, undefined);
  const tasks = L.recoverWorkspace(target, backup, { task: true });
  assert.equal(L.jsonFields(tasks).get("taskAtlas"), L.jsonFields(backup).get("taskAtlas"));
  assert.deepEqual(JSON.parse(tasks).notes, { old: {} });
  assert.equal(JSON.parse(tasks).filesAtlas.request, "current");
  const files = L.recoverWorkspace(target, backup, { files: true });
  assert.equal(JSON.parse(files).filesAtlas.request, "draft");
  assert.deepEqual(JSON.parse(files).taskAtlas, { items: [] });
  assert.throws(() => L.recoverWorkspace(target, backup, {}), /Select/);
});

test("patches and appends never normalize untouched legacy fields or large numbers", () => {
  const patched = L.patchLibraryJSON(backup, { projectNotes: "A note" });
  for (const [key, value] of L.jsonFields(backup)) assert.equal(L.jsonFields(patched).get(key), value);
  const appended = L.appendLibraryItem(patched, "groups", { name: "Invoices", paths: ["A.cls"] });
  assert.equal(JSON.parse(appended).groups[0].name, "Invoices");
  assert.equal(L.jsonFields(appended).get("future"), L.jsonFields(backup).get("future"));
  assert.throws(() => L.jsonFields('{"duplicate":1,"duplicate":2}'), /Duplicate/);
  // Archival import itself still permits duplicates, preserving their exact raw bytes.
  assert.equal(L.workspacePreview('{"duplicate":1,"duplicate":2}').bytes, 29);
});

test("size bounds use UTF-8 bytes and reject instead of cutting off endings", () => {
  const raw = JSON.stringify({ notes: "x".repeat(150000) + "END", future: { unknown: true } });
  assert.equal(L.checkLibraryJSON(raw).notes.endsWith("END"), true);
  assert.equal(L.checkLibraryJSON(JSON.stringify({ value: "é".repeat(500001) })).value.length, 500001);
  assert.throws(() => L.checkLibraryJSON(JSON.stringify({ value: "é".repeat(L.MAX_LIBRARY_BYTES / 2) })), /100 MiB/);
  assert.throws(() => L.checkLibraryJSON("[]"), /object/);
  assert.throws(() => L.checkLibraryJSON('{"a":'), SyntaxError);
});

test("persistent extraction keeps sections and warnings; existing readDocument preserves its exports", async () => {
  const bytes = new TextEncoder().encode("first\nlast");
  const document = await L.readLibraryDocument("notes.txt", bytes);
  assert.equal(document.sections[0].text, "first\nlast");
  assert.ok(document.warnings[0].includes("UTF-8"));
  const attached = await L.readDocument("notes.txt", bytes);
  assert.equal(attached.text, "[Text]\nfirst\nlast");
  assert.ok(attached.warnings.length);
  const unavailable = await L.readLibraryDocument("file.pdf", bytes);
  assert.equal(unavailable.state, "unavailable");
  assert.match(unavailable.notice, /Unsupported/);
  for (const key of ["readDocument", "checkFiles", "buildFile", "artifactPreview", "emailHTML", "emailText"])
    assert.equal(typeof L[key], "function", key);
});

test("document outline, targeted section requests and search are paged without truncation", () => {
  const document = { path: "notes.txt", kind: "Text", state: "readable", notice: "Text only", sections: [{ id: "body", label: "Body", text: Array.from({ length: 260 }, (_, n) => `match ${n + 1}`).join("\n") }] };
  assert.match(L.libraryDocumentContext(document).text, /"lines": 260/);
  const context = L.libraryDocumentContext(document, { section: "body", start: 201, end: 260 }).text;
  assert.match(context, /260 \| match 260/);
  assert.match(context, /LIMITATIONS: Text only/);
  assert.throws(() => L.libraryDocumentContext(document, { section: "body", start: 1, end: 260 }), /at most 200/);
  assert.throws(() => L.libraryDocumentContext(document, { section: "missing" }), /Section not found/);
  const lines = [];
  let cursor = 0;
  do {
    const page = L.searchDocument(document, "MATCH", cursor, 50);
    lines.push(...page.matches.map((m) => m.line));
    cursor = page.nextCursor;
    assert.equal(page.total, 260);
  } while (cursor !== null);
  assert.deepEqual(lines, Array.from({ length: 260 }, (_, i) => i + 1));
  assert.throws(() => L.searchDocument(document, "match", -1), /cursor/);
});

test("notebook context includes relevant notes, briefs, feature groups and source snippets", () => {
  let raw = JSON.stringify(L.newNotebook());
  raw = L.patchLibraryJSON(raw, {
    projectNotes: "Billing service",
    notes: { "A.cls": { notes: "A note" }, "B.cls": { notes: "B note" } },
    brief: { purpose: { text: "Purpose", enabled: true }, testing: { text: "Hidden", enabled: false }, glossary: { text: "B only", scope: "B.cls" } },
    groups: [{ name: "A feature", paths: ["A.cls"] }, { name: "B feature", paths: ["B.cls"] }],
    snippets: [{ path: "A.cls", start: 10, end: 10, text: "public class A {}" }],
  });
  const context = L.sourceNotebookContext(raw, "A.cls").text;
  assert.match(context, /Billing service/);
  assert.match(context, /A note/);
  assert.match(context, /A feature/);
  assert.match(context, /public class A/);
  assert.doesNotMatch(context, /B note|B feature|Hidden/);
  assert.match(context, /omitted by scope/);
  assert.throws(() => L.sourceNotebookContext(JSON.stringify({ projectNotes: "x".repeat(100000) })), /nothing was cut/);
});

test("paged document and notebook context reconstruct complete large content", () => {
  const text = "é".repeat(150000) + "END";
  const document = {path: "long.txt", state: "readable", sections: [{id: "s", label: "Long line", text}]};
  const collect = (read) => {
    let offset = 0, joined = "";
    do { const page = read(offset); assert.equal(page.offset, offset); joined += page.text; offset = page.nextOffset; } while (offset !== null);
    return joined;
  };
  const result = collect((offset) => L.libraryDocumentContext(document, {section: "s", start: 1, end: 1}, {offset, maxChars: 10000}));
  assert.ok(result.includes(text));
  assert.match(result, /END DOCUMENT/);
  const notebook = JSON.stringify({projectNotes: text});
  assert.ok(collect((offset) => L.sourceNotebookContext(notebook, "", {offset, maxChars: 10000})).includes(text));
  const search = L.searchDocument(document, "é");
  assert.equal(search.matches[0].excerptOnly, true);
  assert.equal(search.matches[0].characters, text.length);
  assert.equal(search.matches[0].text.length, 2000);
  assert.throws(() => L.contextPage(["a"], {offset: 2}), /exceeds/);
});

test("source snapshots preserve neighboring raw JSON and require explicit replacement", async () => {
  const huge = "900719925474099312345";
  let raw = `{"future":${huge},"sources":[{"path":"classes/A.cls","text":"public class A {}","future":${huge}}],"pack":[]}`;
  raw = await L.saveSourceSnapshot(raw, {path: "lwc/demo/demo.js", text: "import run from '@salesforce/apex/A.run'; import missing from 'c/missing';"});
  assert.equal(L.jsonFields(raw).get("future"), huge);
  assert.match(L.jsonItems(L.jsonFields(raw).get("sources"))[0], new RegExp(huge));
  await assert.rejects(L.saveSourceSnapshot(raw, {path: "classes/A.cls", text: "public class A { public static void run() {} }"}), /explicitly replace/);
  raw = await L.saveSourceSnapshot(raw, {path: "classes/A.cls", text: "public class A { public static void run() {} }"}, true);
  assert.match(L.jsonItems(L.jsonFields(raw).get("sources"))[0], new RegExp(huge));
  const graph = L.sourceGraph(raw);
  assert.equal(graph.edges.length, 1);
  assert.ok(graph.refs.some((r) => r.target === "missing" && !r.to));
  raw = L.savePackSelection(raw, {path: "classes/A.cls", mode: "full"});
  raw = L.savePackSelection(raw, {path: "lwc/demo/demo.js", mode: "outline"});
  const pack = L.sourcePackContext(raw).text;
  assert.match(pack, /public static void run/);
  assert.match(pack, /OUTLINE ONLY/);
  const updated = await L.saveSourceSnapshot(raw, {path: "classes/A.cls", text: "public class A {}"}, true);
  assert.match(L.sourcePackContext(updated).text, /CHANGED SNAPSHOT/);
  assert.match(L.sourceFileContext(raw, {path: "classes/A.cls", start: 1, end: 1}).text, /1 \| public class A/);
  assert.throws(() => L.savePackSelection(raw, {path: "classes/A.cls", mode: "range", start: 1, end: 2}), /existing/);
  await assert.rejects(L.saveSourceSnapshot(raw, {path: "../wrong", text: ""}), /relative/);
  assert.deepEqual(L.jsonItems(' [ {"a":[1,2]}, "a,\\\"b", 900719925474099312345 ] '), ['{"a":[1,2]}', '"a,\\\"b"', huge]);
});

test("rich email clipboard contains generated escaped HTML, not executable pasted markup", async () => {
  const copied = {}, listeners = new Map();
  const prior = globalThis.document;
  const container = { appendChild() {} };
  globalThis.document = {
    body: container, activeElement: null,
    createElement: () => ({ style: {}, focus() {}, select() {}, remove() {} }),
    addEventListener: (type, handler) => listeners.set(type, handler),
    removeEventListener: (type) => listeners.delete(type),
    execCommand: () => { listeners.get("copy")({ clipboardData: { setData: (type, value) => { copied[type] = value; } }, preventDefault() {} }); return true; },
  };
  try {
    const email = { kind: "email", name: "message.eml", subject: "Hello", blocks: [{ type: "paragraph", text: '<script>alert(1)</script><img src=x onerror="bad">' }] };
    assert.equal(await L.copyRichEmail(email, container), true);
    assert.doesNotMatch(copied["text/html"], /<script|<img/);
    assert.match(copied["text/html"], /&lt;script&gt;/);
    assert.equal(copied["text/plain"], email.blocks[0].text);
    assert.throws(() => L.copyRichEmail({ ...email, html: "<script>bad</script>" }, container), /Unsupported|Unknown|unknown|unexpected/i);
  } finally { globalThis.document = prior; }
});
