import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const dir = await mkdtemp(join(tmpdir(), "atlas-storage-"));
const outfile = join(dir, "storage.mjs");
await build({
  entryPoints: [new URL("../salesforce/force-app/main/default/lwc/atlasStorage/atlasStorage.js", import.meta.url).pathname],
  bundle: true, platform: "node", format: "esm", outfile,
  plugins: [{ name: "apex", setup(b) {
    b.onResolve({ filter: /^@salesforce\/apex\// }, ({path}) => ({path, namespace: "apex"}));
    b.onLoad({ filter: /.*/, namespace: "apex" }, ({path}) => ({contents: `export default args => globalThis.storageApex(${JSON.stringify(path.split(".").at(-1))}, args);`}));
  }}],
});
const S = await import(outfile);
await rm(dir, { recursive: true });

const args = (dataJson, title = "Archive") => ({recordId: null, title, kind: "workspace", expectedRevision: 0, dataJson});

test("chunks preserve Unicode code points and the exact raw JSON", () => {
  const raw = '{ "future":900719925474099312345,"text":"' + "x".repeat(189960) + "🐻".repeat(100000) + '" }';
  const chunks = S.archiveChunks(raw);
  assert.equal(chunks.join(""), raw);
  for (const chunk of chunks) {
    assert.ok(chunk.length <= 190000);
    assert.equal(new TextDecoder().decode(new TextEncoder().encode(chunk)), chunk);
  }
});

test("existing small saves use one call, new saves reserve an explicit identity, and invalid JSON never reaches Apex", async () => {
  const calls = [];
  globalThis.storageApex = async (name, input) => { calls.push({name, input}); return '{"id":"saved","revision":1}'; };
  const raw = '{"unknown":900719925474099312345}';
  assert.equal((await S.writeLibrary({...args(raw), recordId: "existing"})).id, "saved");
  assert.equal(calls[0].name, "saveEntry");
  assert.equal(calls[0].input.dataJson, raw);
  await assert.rejects(() => S.writeLibrary(args(raw)), /creation identity/);
  await assert.rejects(() => S.writeLibrary(args("[]")), /object/);
  assert.equal(calls.length, 1);
  await S.writeLibrary({...args(raw), creationKey: "new-entry"});
  assert.equal(calls[1].name, "reserveRecovery");
  assert.equal(calls[1].input.recoveryKey, "create:new-entry");
  assert.equal(calls[2].name, "saveEntry");
  assert.equal(calls[2].input.recordId, "saved");
  assert.equal(calls[2].input.expectedRevision, 0);
  assert.equal(calls[2].input.dataJson, raw);
  assert.equal(Object.hasOwn(calls[2].input, "creationKey"), false);
});

test("interrupted writes and lost commit responses resume without starting a new archive", async () => {
  const raw = JSON.stringify({text: "é".repeat(600000), future: "END"});
  let begun = 0, failWrite = true, failCommit = true, committed = false;
  const parts = new Map();
  globalThis.storageApex = async (name, input) => {
    if (name === "beginUpload") { begun++; return "upload"; }
    if (name === "writePart") {
      if (parts.has(input.index)) assert.equal(parts.get(input.index), input.text);
      parts.set(input.index, input.text);
      if (input.index === 1 && failWrite) { failWrite = false; throw Error("Lost chunk response"); }
      return;
    }
    assert.equal(name, "commitUpload");
    assert.equal([...parts.values()].join(""), raw);
    committed = true;
    if (failCommit) { failCommit = false; throw Error("Lost commit response"); }
    return {id: "saved", revision: 1};
  };
  await assert.rejects(() => S.writeLibrary(args(raw, "Resume")), /chunk response/);
  assert.equal(committed, false);
  await assert.rejects(() => S.writeLibrary({...args(raw, "Resume"), creationKey: "unrelated-small-save-identity"}), /commit response/);
  assert.equal(committed, true);
  assert.equal((await S.writeLibrary(args(raw, "Resume"))).id, "saved");
  assert.equal(begun, 1);
});

test("small recovery retries still validate the exact body even when the reservation has committed", async () => {
  const calls = [];
  globalThis.storageApex = async (name, input) => {
    calls.push({name, input});
    if (name === "reserveRecovery") return {id: "saved", revision: 1, versionId: "v1"};
    assert.equal(name, "saveEntry"); assert.equal(input.recordId, "saved"); assert.equal(input.expectedRevision, 0);
    if (input.dataJson !== '{"original":true}') throw Error("Library revision conflict");
    return {id: "saved", revision: 1, versionId: "v1"};
  };
  assert.equal((await S.restoreLibrary(args('{"original":true}'), "immutable-recovery")).versionId, "v1");
  await assert.rejects(() => S.restoreLibrary(args('{"changed":true}'), "immutable-recovery"), /revision conflict/);
  assert.deepEqual(calls.map((call) => call.name), ["reserveRecovery", "saveEntry", "reserveRecovery", "saveEntry"]);
});

test("chunk reads verify shape, sizes and historical version selection", async () => {
  const raw = '{"unknown":900719925474099312345,"text":"🐻é"}';
  const chunks = S.archiveChunks(raw);
  const manifest = {type: "atlas-chunked", count: chunks.length, bytes: new TextEncoder().encode(raw).length,
    chars: raw.length, parts: Object.fromEntries(chunks.map((text, i) => [i, {chars: text.length}]))};
  globalThis.storageApex = async (name, input) => {
    if (name === "loadVersion") return {id: "entry", versionId: "latest", loadedVersionId: "older", dataJson: JSON.stringify(manifest)};
    assert.equal(name, "readPart"); assert.equal(input.versionId, "older"); return chunks[input.index];
  };
  const input = {recordId: "entry", versionId: "older"};
  assert.equal((await S.readLibrary(input)).dataJson, raw);
  manifest.bytes++;
  await assert.rejects(() => S.readLibrary(input), /size verification/);
  manifest.bytes--;
  manifest.parts = {};
  await assert.rejects(() => S.readLibrary(input), /missing a chunk/);
  manifest.count = 100000;
  await assert.rejects(() => S.readLibrary(input), /Invalid archive manifest/);
});

test("chunked reads run four parts at a time, keep their order and parse the entry once", async () => {
  const raw = JSON.stringify({text: "é".repeat(900000), future: "END"});
  const chunks = S.archiveChunks(raw);
  assert.ok(chunks.length > 4);
  const manifest = {type: "atlas-chunked", count: chunks.length, bytes: new TextEncoder().encode(raw).length,
    chars: raw.length, parts: Object.fromEntries(chunks.map((text, i) => [i, {chars: text.length}]))};
  let active = 0, most = 0;
  globalThis.storageApex = async (name, input) => {
    if (name === "loadEntry") return {id: "entry", kind: "document", dataJson: JSON.stringify(manifest)};
    assert.equal(name, "readPart");
    active++; most = Math.max(most, active);
    // Later parts answer first, so the order must come from the index, not arrival.
    await new Promise((resolve) => setTimeout(resolve, (chunks.length - input.index) * 2));
    active--;
    return chunks[input.index];
  };
  const read = await S.readLibrary({recordId: "entry"});
  assert.equal(read.dataJson, raw);
  assert.equal(most, 4);
  const parsed = S.libraryData(read);
  assert.equal(parsed.future, "END");
  assert.equal(S.libraryData(read), parsed, "the parse readLibrary did is reused");
  // Small entries hand back the row itself, already parsed.
  globalThis.storageApex = async () => ({id: "small", dataJson: '{"a":1}'});
  const small = await S.readLibrary({recordId: "small"});
  assert.equal(S.libraryData(small), S.libraryData(small));
  assert.deepEqual(S.libraryData({dataJson: '{"b":2}'}), {b: 2});
});

test("inOrder keeps results in input order, respects the limit and stops starting work after a failure", async () => {
  let active = 0, most = 0;
  const order = await S.inOrder([5, 1, 4, 2, 3], 2, async (n, i) => {
    active++; most = Math.max(most, active);
    await new Promise((resolve) => setTimeout(resolve, n));
    active--;
    return `${i}:${n}`;
  });
  assert.deepEqual(order, ["0:5", "1:1", "2:4", "3:2", "4:3"]);
  assert.equal(most, 2);
  assert.deepEqual(await S.inOrder([], 4, async () => { throw Error("never"); }), []);
  const started = [];
  await assert.rejects(S.inOrder([0, 1, 2, 3, 4, 5], 2, async (n) => {
    started.push(n);
    if (n === 1) throw Error("stop");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }), /stop/);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(started, [0, 1], "nothing new starts once one part fails");
});
