import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
const dir = await mkdtemp(join(tmpdir(), "support-tickets-"));
const root = new URL("../salesforce/force-app/main/default/lwc/atlasLib/", import.meta.url).pathname;
await build({ entryPoints: [join(root, "jira.js")], bundle: true, platform: "node", format: "esm", outfile: join(dir, "jira.mjs") });
const J = await import(join(dir, "jira.mjs"));
await rm(dir, { recursive: true });

test("duplicate CSV keys are rejected before any import chunks", () => {
  assert.throws(() => J.importRows(J.parseCSV("Issue key,Summary\nA-1,First\na-1,Second\n")), /duplicate/i);
});
test("duplicate standard headers are blocked while exact mappings resolve distinct spellings", () => {
  for (const headers of ["Issue key,Summary,Summary", "Issue key,Summary,Due Date,Due-date", "Issue key,Summary,Assignee Id,Assignee ID"]) {
    assert.throws(() => J.importRows(J.parseCSV(headers + "\nAB-1,Title,One,Two\n")), /Ambiguous CSV columns/);
  }
  const mapped = J.importRows(J.parseCSV("Issue key,Summary,Due Date,Due-date,Chosen parent\nAB-1,Title,2026-10-15,2026-11-01,AB-99\n"), {
    mapping: { headers: { dueDate: "Due-date", epicLink: "Chosen parent" } }
  });
  assert.equal(mapped.rows[0].dueDate, "2026-11-01"); assert.equal(mapped.rows[0].epicKey, "AB-99");
  const identity = J.importColumns(["Issue key", "Summary", "Assignee", "Assignee Id"]);
  assert.equal(identity.assignee, 3, "Account IDs retain priority over display names");
});

test("raw repeated/custom columns and whitespace survive a snapshot export", () => {
  const parsed = J.parseCSV('Issue key,Summary,Comment,Comment,Custom field (Risk)\nAB-1,Title," first ",second,high\n');
  const { rows } = J.importRows(parsed);
  assert.deepEqual(rows[0].raw, { headers: parsed.headers, values: parsed.rows[0] });
  const roundtrip = J.parseCSV(J.rawExportCSV([{ raw: rows[0].raw }]).csv);
  assert.deepEqual(roundtrip.headers, parsed.headers);
  assert.deepEqual(roundtrip.rows, parsed.rows);
});
test("unknown assignees demand explicit reconciliation rather than becoming unassigned", () => {
  const { rows } = J.importRows(J.parseCSV("Issue key,Summary,Assignee\nAB-1,Title,unknown-id\n"));
  assert.equal(rows[0].unresolvedAssignee, "unknown-id");
  const review = J.reviewImportRows(rows, [], []);
  assert.equal(review[0].needsAssignee, true);
});
test("epic-first creation never substitutes an epic name for a Jira key", () => {
  assert.throws(() => J.exportCSV([{ id: "E", issueType: "Epic", summary: "Epic" }, { id: "T", issueType: "Task", epicId: "E", summary: "Task" }]), /epic.*first|unresolved/i);
});
test("draft reconciliation is project-aware and ambiguity requires a choice", () => {
  const drafts = ["AB", "XY", "AB"].map((projectKey, i) => ({ id: String(i), summary: "Same", issueType: "Task", stage: "Draft", projectKey }));
  const review = J.reviewImportRows([{ key: "AB-1", summary: "Same", issueType: "Task" }], drafts, []);
  assert.deepEqual(review[0].candidates.map(t => t.id), ["0", "2"]);
  assert.equal(review[0].needsMatch, true);
  assert.equal(review[0].resolution, "");
});
