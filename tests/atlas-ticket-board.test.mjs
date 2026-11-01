// Exercise the real board and helpers; only Lightning and server boundaries are stubbed.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-ticket-board-"));
let Tickets;
try {
  const outfile = join(dir, "tickets.mjs");
  await build({
    entryPoints: [join(root, "atlasTickets/atlasTickets.js")], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{ name: "lightning-boundaries", setup(b) {
      b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
      b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
        path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};" :
        path.startsWith("@salesforce/apex/") ? `export default (args) => globalThis.ticketBoardApex(${JSON.stringify(path.split(".").at(-1))}, args);` :
        path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"
      }));
      b.onResolve({ filter: /^c\/atlas/ }, ({ path }) => ({ path: join(root, path.slice(2), path.slice(2) + ".js") }));
      b.onLoad({ filter: /\/atlas[^/]+\/atlas[^/]+\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
    }}],
  });
  Tickets = (await import(outfile)).default;
} finally { await rm(dir, { recursive: true }); }

const statuses = ["Registered", "Not Started", "Planning", "Working", "Waiting On Others", "On Hold", "Ready To Release", "Completed", "Cancelled"];
const fallbackLabel = "Other / no Jira status";
const ticket = (id, jiraStatus, planning = {}) => ({ id, atlasId: `TKT-${id}`, summary: `Ticket ${id}`, issueType: "Task", stage: "In Jira", jiraStatus, planning });
function board(tickets) { const c = new Tickets(); c.owner = "everyone"; c.tickets = tickets; return c; }

test("a Working Jira ticket without a manual lane belongs to Working, not Backlog", () => {
  const c = board([ticket("1", "Working")]);
  assert.equal(c.columns.find((column) => column.cards.some((card) => card.id === "1"))?.label, "Working");
});

test("blank and unfamiliar Jira statuses stay visible without claiming a real workflow status", () => {
  const records = [null, undefined, "", "   ", "QA Review", "Done"].map((status, i) => ticket(String(i), status, { lane: "Done" }));
  const c = board(records), before = structuredClone(records);
  const fallback = c.columns.find((column) => column.label === "Other / no Jira status");
  assert.deepEqual(c.columns.slice(0, 9).map((column) => column.label), statuses);
  assert.equal(c.columns.length, 10);
  assert.deepEqual(fallback.cards.map((card) => card.id), records.map((t) => t.id));
  assert.equal(fallback.cards[0].mirror, "No Jira status");
  assert.equal(fallback.cards[4].mirror, "QA Review");
  assert.equal(fallback.cards[5].mirror, "Done", "Do not invent a Completed status from a different workflow");
  assert.deepEqual(records, before, "Grouping never rewrites Jira or planning data");
});

test("all nine Jira statuses keep the requested order regardless of manual lane", () => {
  const records = statuses.map((status, i) => ticket(String(i), status, { lane: "Blocked" }));
  const c = board(records), before = structuredClone(records);
  assert.deepEqual(c.columns.map((column) => column.label), statuses);
  for (const [i, column] of c.columns.entries()) {
    assert.equal(column.count, 1);
    assert.equal(column.empty, false);
    assert.equal(column.cards[0].id, String(i));
  }
  assert.deepEqual(records, before);
  assert.equal(c.columns, c.columns, "Repeated renders reuse the board");
  assert.deepEqual(board([]).columns.map((column) => [column.label, column.count, column.empty]), statuses.map((s) => [s, 0, true]));
});

test("owner, epic and text filters still apply before status grouping", () => {
  const c = board([
    { ...ticket("epic", "Planning"), issueType: "Epic", assigneeId: "me" },
    { ...ticket("child", "Working"), epicId: "epic", assigneeId: "me" },
    { ...ticket("other", "Working"), epicId: "epic", assigneeId: "someone" },
    { ...ticket("unassigned", null), assigneeId: null },
  ]);
  c.boot = { people: [{ id: "me", isMe: true }] }; c.owner = "me"; c.epic = "epic"; c.search = "child";
  assert.deepEqual(c.columns.flatMap((column) => column.cards.map((t) => t.id)), ["child"]);
  c.owner = "unassigned"; c.epic = ""; c.search = "";
  assert.deepEqual(c.columns.find((column) => column.label === fallbackLabel).cards.map((t) => t.id), ["unassigned"]);
  c.tickets = [ticket("refreshed", "Cancelled")]; c.owner = "everyone";
  assert.deepEqual(c.columns.find((column) => column.label === "Cancelled").cards.map((t) => t.id), ["refreshed"]);
});

test("the editor still loads and saves manual planning independently of Jira status", async () => {
  const t = { ...ticket("1", "Working", { lane: "Next", blockerNote: "Waiting", dependencies: ["TKT-2"], followUp: "2026-10-25", snooze: "2026-10-24" }), version: "v1" };
  const c = board([t]), writes = [];
  globalThis.ticketBoardApex = async (name, args) => {
    if (name === "getTicket") return t;
    if (name === "ticketFiles") return JSON.stringify({ files: [], nextCursor: null });
    if (name === "saveTicket") { writes.push(JSON.parse(args.ticketJson)); return t.id; }
    if (name === "boardPage") return { tickets: [t], nextCursor: null };
    assert.fail(`Unexpected server call: ${name}`);
  };
  await c.fetchTicket(t.id);
  assert.equal(c.editing.lane, "Next");
  assert.deepEqual(c.laneOptions.map((option) => option.value), ["Backlog", "Next", "In progress", "Blocked", "Done"]);
  c.editing = { ...c.editing, lane: "Blocked" };
  await c.saveSelected();
  assert.equal(c.error, null);
  assert.equal(writes.length, 1);
  assert.deepEqual(writes[0].planning, { ...t.planning, lane: "Blocked" });
  assert.equal(Object.hasOwn(writes[0], "jiraStatus"), false);
  assert.equal(c.columns.find((column) => column.label === "Working").count, 1);
});

test("board layout wraps readable columns and uses shared status accents", async () => {
  const css = await readFile(join(root, "atlasTickets/atlasTickets.css"), "utf8");
  const boardRule = css.match(/\.atlas-board\s*\{([^}]+)\}/)[1];
  assert.match(boardRule, /grid-template-columns:\s*repeat\(auto-fit,\s*minmax\(min\(100%,\s*16rem\),\s*1fr\)\)/);
  assert.doesNotMatch(boardRule, /overflow|max-height/);
  for (const status of statuses) {
    const className = status.toLowerCase().replace(/\s+/g, "-");
    assert.match(css, new RegExp(`\\.atlas-column_${className}\\s*\\{[^}]*--atlas-lane: var\\(--atlas-`));
  }
  assert.doesNotMatch(css.split("/* ---- board ---- */")[1].split("/* ---- editor ---- */")[0], /#[\da-f]{3,8}\b/i);
});

test("board and planning copy explain saved Jira status grouping without renaming editor controls", async () => {
  const html = await readFile(join(root, "atlasTickets/atlasTickets.html"), "utf8");
  assert.match(html, /arranged by saved Jira status/);
  assert.match(html, /Planning lanes are saved separately and do not determine board columns/);
  assert.match(html, /label="Planning lane \(separate from Jira status\)"/);
  assert.match(html, /Other \/ no Jira status/);
});
