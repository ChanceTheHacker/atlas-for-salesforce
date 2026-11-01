import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-jira-protocol-"));
const modules = {};
for (const name of ["settings", "prompts", "replies", "jira-live", "cache"]) {
  const outfile = join(dir, name + ".mjs");
  await build({ entryPoints: [join(root, "atlasLib", name + ".js")], bundle: true, platform: "node", format: "esm", outfile });
  modules[name] = await import(outfile);
}
const outfile = join(dir, "conversation.mjs");
await build({ entryPoints: [join(root, "atlasConversation/atlasConversation.js")], bundle: true, platform: "node", format: "esm", outfile,
  plugins: [{ name: "native-platform", setup(b) {
    b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
    b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
      path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};" :
      path.startsWith("@salesforce/apex/") ? `export default (args) => globalThis.atlasJiraApex(${JSON.stringify(path.split(".").at(-1))}, args);` :
      path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';" }));
    b.onResolve({ filter: /^c\/atlas/ }, ({ path }) => ({ path: join(root, path.slice(2), path.slice(2) + ".js") }));
    b.onLoad({ filter: /\/atlas[^/]+\/atlas[^/]+\.js$/ }, async ({ path }) => ({ contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js" }));
  } }],
});
const Conversation = (await import(outfile)).default;
await rm(dir, { recursive: true });

const boot = { org: { id: "org", name: "Test", edition: "Enterprise" }, user: { id: "user", name: "Tester" }, people: [] };
const prompt = (jira) => modules.prompts.firstPrompt({ conversation: { title: "Ticket", request: "Check it" }, boot, mine: { replyLimit: 100000 }, jira });
const configured = { projectKey: "ABC", apiBaseUrl: "https://jira.example.test", namedCredential: "Atlas_Jira_Connection", externalCredential: "Atlas_Jira_Auth" };

test("missing credentials keep manual Jira and separate disabled capability defaults", () => {
  const settings = modules.settings.readSettings({ settings: { jira: JSON.stringify({ siteUrl: "https://jira.example.test", readEnabled: true, writeEnabled: true }) } });
  assert.equal(settings.jira.readEnabled, true);
  assert.equal(settings.jira.writeEnabled, true);
  const text = prompt({ ...settings.jira, externalCredential: "" });
  assert.match(text, /manual: no live credential/i);
  assert.match(text, /export new tickets as CSV/i);
  assert.doesNotMatch(text, /Live reads run immediately/i);
  assert.doesNotMatch(text, /WRITE JIRA: atlas-jira-write/i);
  assert.deepEqual([modules.settings.readSettings({}).jira.readEnabled, modules.settings.readSettings({}).jira.writeEnabled], [false, false]);
});

test("independent read and write switches produce honest agent instructions", () => {
  const readOnly = prompt({ ...configured, readEnabled: true, writeEnabled: false });
  assert.match(readOnly, /Live reads: enabled.*Live writes: disabled/);
  assert.match(readOnly, /jql/i);
  assert.match(readOnly, /nextPageToken/);
  assert.match(readOnly, /startAt/);
  assert.match(readOnly, /local-tickets/i);
  assert.match(readOnly, /Live writes are DISABLED/);
  const writeOnly = prompt({ ...configured, readEnabled: false, writeEnabled: true });
  assert.match(writeOnly, /Live reads: disabled.*Live writes: enabled/);
  assert.match(writeOnly, /Live reads are DISABLED/);
  assert.match(writeOnly, /WRITE JIRA: atlas-jira-write/);
  assert.match(writeOnly, /human review/i);
});

test("write envelopes pin conversation and operation identity and reject agent-controlled transport or approval", () => {
  const { checkJiraWrite } = modules["jira-live"];
  const base = { type: "atlas-jira-write", requestId: "conversation-1", operationId: "fix_ABC-1", operation: "update", issueKey: "ABC-1", fields: { summary: "Exact title" } };
  assert.deepEqual(checkJiraWrite(base, "conversation-1"), { requestId: "fix_ABC-1", operation: "update", issueKey: "ABC-1", fields: { summary: "Exact title" } });
  for (const changes of [{ requestId: "other" }, { operationId: "" }, { operationId: "../retry" }, { approved: true }, { url: "https://elsewhere.test" }, { headers: { Authorization: "token" } }, { operation: "delete" }, { body: "extra" }, { issueKey: "not-a-key" }])
    assert.throws(() => checkJiraWrite({ ...base, ...changes }, "conversation-1"), undefined, JSON.stringify(changes));
  assert.deepEqual(checkJiraWrite({ type: "atlas-jira-write", requestId: "conversation-1", operationId: "comment-1", operation: "comment", issueKey: "ABC-1", body: "Exact comment" }, "conversation-1"), { requestId: "comment-1", operation: "comment", issueKey: "ABC-1", body: "Exact comment" });
  assert.throws(() => checkJiraWrite({ type: "atlas-jira-write", requestId: "conversation-1", operationId: "transition-1", operation: "transition", issueKey: "ABC-1", transitionId: "Done" }, "conversation-1"));
});

test("unconfirmed write outcomes never claim Jira success", () => {
  const { jiraWriteReply } = modules["jira-live"];
  for (const state of ["reviewed", "queued", "unknown", "failed", "invalidated"]) {
    const result = jiraWriteReply({ requestId: "stable-1", id: "receipt", operation: "comment", state }, "conversation-1");
    const parsed = JSON.parse(result.split("\n\n")[0]);
    assert.equal(parsed.confirmed, false, state);
    assert.equal(parsed.operationId, "stable-1");
    assert.equal(parsed.requestId, "conversation-1");
    assert.doesNotMatch(parsed.note, /Jira confirmed this operation/);
  }
  assert.match(jiraWriteReply({ requestId: "stable-1", state: "unknown" }, "conversation-1"), /Never blindly resend/);
  assert.equal(JSON.parse(jiraWriteReply({ requestId: "stable-1", state: "succeeded" }, "conversation-1").split("\n\n")[0]).confirmed, true);
});

test("live Jira and ambiguous tickets bypass cache while the explicitly local mirror retains its snapshot", async () => {
  const { cachedResearch, invalidateResearch } = modules.cache;
  const scope = "jira-cache-org:jira-cache-user";
  let reads = 0;
  const fetch = async () => ({ serial: ++reads });
  try {
    for (const op of ["jira", "tickets"]) {
      const request = { id: "one", op, keys: ["ABC-1"] };
      const first = await cachedResearch(scope, request, fetch);
      const second = await cachedResearch(scope, request, fetch);
      assert.equal(first.cache.hit, false);
      assert.equal(second.cache.hit, false, `${op} must re-check the server after a settings switch`);
      assert.notEqual(first.result.serial, second.result.serial);
    }
    const local = { id: "one", op: "local-tickets", keys: ["ABC-1"] };
    const first = await cachedResearch(scope, local, fetch);
    const second = await cachedResearch(scope, local, fetch);
    assert.equal(second.cache.hit, true);
    assert.deepEqual(second.result, first.result);
  } finally { invalidateResearch(scope); }
});

test("direct write preparation stores the exact proposal without approving it, and failure never presents a review", async () => {
  const c = new Conversation(), previous = globalThis.atlasJiraApex;
  c.conversationId = "conversation-1"; c.jiraWrites = []; c.settings = {mine: {replyLimit: 100000}};
  const messages = [], calls = [];
  c.send = async (kind, body) => messages.push({kind, body});
  const proposal = {type: "atlas-jira-write", requestId: "conversation-1", operationId: "stable-1", operation: "comment", issueKey: "ABC-1", body: "Exact message"};
  let reject = false;
  globalThis.atlasJiraApex = async (name, args) => {
    calls.push({name, args}); assert.equal(name, "prepareWrite", "The conversation must not invoke approval or execution");
    if (reject) throw Error("Write permission disabled");
    return JSON.stringify({id: "receipt-1", requestId: "stable-1", operation: "comment", state: "reviewed"});
  };
  try {
    await c.reviewJiraWrite(proposal);
    assert.deepEqual(calls.map(({name}) => name), ["prepareWrite"]);
    assert.deepEqual(JSON.parse(calls[0].args.requestJson), {requestId: "stable-1", operation: "comment", issueKey: "ABC-1", body: "Exact message"});
    assert.equal(c.jiraWrites[0].state, "reviewed");
    assert.equal(JSON.parse(messages[0].body.split("\n\n")[0]).confirmed, false);
    reject = true;
    await assert.rejects(c.reviewJiraWrite({...proposal, operationId: "stable-2"}), /Write permission disabled/);
    assert.equal(c.jiraWrites.length, 1);
    assert.equal(messages.length, 1);
  } finally { globalThis.atlasJiraApex = previous; }
});

test("configured live refresh checks real capabilities, sends one scoped Jira search, and never falls back on disabled Read", async () => {
  const c = new Conversation(), previous = globalThis.atlasJiraApex;
  c.connected = true; c.conversationId = "conversation-1";
  const requests = []; c.runRequests = async (message) => requests.push(message);
  let readEnabled = true;
  globalThis.atlasJiraApex = async (name) => {
    assert.equal(name, "capabilities");
    return JSON.stringify({connected: true, readEnabled, writeEnabled: false});
  };
  const keys = Array.from({length: 100}, (_, i) => `ABC-${i + 1}`);
  try {
    await c.requestJiraRefresh({keys});
    assert.equal(requests.length, 1);
    assert.equal(requests[0].fresh, true);
    assert.equal(requests[0].requests.length, 1);
    assert.equal(requests[0].requests[0].op, "jira");
    assert.equal(requests[0].requests[0].action, "search");
    assert.equal(requests[0].requests[0].maxResults, 50);
    assert.match(requests[0].requests[0].jql, /"ABC-1"/);
    assert.match(requests[0].requests[0].jql, /"ABC-100"/);
    assert.equal(c.refreshRequest, null);
    readEnabled = false;
    await assert.rejects(c.requestJiraRefresh({keys: ["ABC-1"]}), /Read is disabled/);
    assert.equal(requests.length, 1, "Disabled read cannot use the mirror as live evidence");
    assert.equal(c.refreshRequest, null);
  } finally { globalThis.atlasJiraApex = previous; }
});

test("conversation blocks disabled live reads and labels the local mirror separately", async () => {
  const c = new Conversation();
  c.boot = boot; c.conversationId = "conversation-1"; c.connected = true;
  c.settings = { jira: { ...configured, readEnabled: false, writeEnabled: true }, mine: { replyLimit: 100000 } };
  const bodies = []; c.deferMessages = true; c.outbox = { enqueue: async (message) => bodies.push(message.body) };
  const calls = []; const previous = globalThis.atlasJiraApex;
  globalThis.atlasJiraApex = async (name, args) => { calls.push({ name, args }); if (name === "run" && JSON.parse(args.requestJson).op === "jira") throw Error("Live Jira Read is disabled in Team & Jira"); return JSON.stringify({ tickets: [], hasMore: false }); };
  try {
    await c.runRequests({ requests: [{ id: "live", op: "jira", action: "search", jql: "project = ABC" }] });
    assert.equal(calls.filter(({ name }) => name === "run").length, 1, "The server must enforce the disabled read switch");
    assert.match(bodies.at(-1), /disabled|not enabled/i);
    await c.runRequests({ requests: [{ id: "local", op: "local-tickets", limit: 5 }] });
    assert.ok(calls.some(({ name }) => name === "run"), "Local mirror remains readable");
    assert.match(bodies.at(-1), /Salesforce|mirror|local/i);
  } finally { globalThis.atlasJiraApex = previous; }
});

test("sending a Jira result loads the selected receipt rather than treating a list summary as the full result", async () => {
  const c = new Conversation(), previous = globalThis.atlasJiraApex;
  c.conversationId = "conversation-1";
  c.jiraWrites = [{id: "receipt-1", state: "succeeded", summary: true}];
  c.guard = async (work) => work();
  const sent = [];
  c.send = async (kind, body) => sent.push({kind, body});
  globalThis.atlasJiraApex = async (name, args) => {
    assert.equal(name, "getWrite");
    assert.deepEqual(args, {operationId: "receipt-1"});
    return JSON.stringify({id: "receipt-1", requestId: "stable-1", state: "succeeded", operation: "create", result: {key: "ABC-42"}});
  };
  try {
    await c.sendJiraResult({currentTarget: {dataset: {id: "receipt-1"}}});
    const reply = JSON.parse(sent[0].body.split("\n\n")[0]);
    assert.equal(reply.confirmed, true);
    assert.equal(reply.result.key, "ABC-42");
    assert.equal(c.jiraWrites[0].summary, undefined);
  } finally { globalThis.atlasJiraApex = previous; }
});
