// Ticket exports, batch handoffs and legacy CSVs are saved through Atlas_Tickets.file(),
// which adds a title prefix, and replays find them again by exact Title. If the title a
// caller strips before saving doesn't come back unchanged, replays never find their
// receipt and repeat the work. This reads the real Apex; the Salesforce tests prove it.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const classes = new URL("../salesforce/force-app/main/default/classes/", import.meta.url);
const tickets = await readFile(new URL("Atlas_Tickets.cls", classes), "utf8");
const ticketsTest = await readFile(new URL("Atlas_TicketsTest.cls", classes), "utf8");

const apex = {
  substring: (text, arg) => text.slice(Number(arg)),
  removeStart: (text, arg) => {
    const start = arg.replace(/^'|'$/g, "");
    return text.startsWith(start) ? text.slice(start.length) : text;
  },
};

test("titles saved through file() are the titles Atlas looks up", () => {
  const prefix = tickets.match(/static Id file\(String name[^)]*\) \{[\s\S]*?Title = '([^']*)' \+ name/)?.[1];
  assert.ok(prefix, "file() adds a literal title prefix");
  const calls = [...tickets.matchAll(/\bfile\((\w+)\.(substring|removeStart)\(([^)]*)\)/g)];
  assert.equal(calls.length, 3, "export receipts, batch handoffs and legacy CSV exports");
  for (const call of calls) {
    const [, variable, method, arg] = call;
    const assignments = [...tickets.slice(0, call.index).matchAll(new RegExp(`\\b${variable} = '([^']*)' \\+`, "g"))];
    const title = assignments.at(-1)?.[1];
    assert.ok(title, `${variable} is built from a literal before ${call[0]}`);
    assert.equal(prefix + apex[method](title, arg), title, `${call[0]} saves the title it looks up`);
  }
});

test("the hand-made batch receipt in the Apex test uses the real batch title", () => {
  const batchKey = tickets.match(/String batchKey = '([^']*)' \+/)?.[1];
  const receipt = ticketsTest.match(/receiptOnlyBatchesRecoverTheirHandoffOnceWithoutReapplying[\s\S]*?String title = '([^']*)' \+/)?.[1];
  assert.ok(batchKey && receipt);
  assert.equal(receipt, batchKey);
});
