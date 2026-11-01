// Local component sequences with Salesforce stubbed. Real Files validation and DOCX generation.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import { unzipSync, strFromU8 } from "fflate";
import { DOMParser } from "@xmldom/xmldom";
import * as files from "../salesforce/static-src/atlas-files.js";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-uat-"));
const modules = {};
for (const name of ["atlasLib", "atlasWork", "atlasConversation"]) {
  const outfile = join(dir, `${name}.mjs`);
  await build({entryPoints: [join(root, name, `${name}.js`)], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{name: "lightning-boundaries", setup(b) {
      b.onResolve({filter: /^lwc$|^lightning\/|^@salesforce\//}, ({path}) => ({path, namespace: "platform"}));
      b.onLoad({filter: /.*/, namespace: "platform"}, ({path}) => ({contents:
        path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api=()=>{};" :
        path.startsWith("@salesforce/apex/") ? `export default args=>globalThis.uatApex(${JSON.stringify(path.split(".").at(-1))},args);` :
        path.startsWith("lightning/") ? "export const loadScript=async()=>{};" : "export default 'resource';"}));
      b.onResolve({filter: /^c\/atlas/}, ({path}) => ({path: join(root, path.slice(2), path.slice(2) + ".js")}));
      b.onLoad({filter: /\/atlas[^/]+\/atlas[^/]+\.js$/}, async ({path}) => ({contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js"}));
    }}],
  });
  modules[name] = await import(outfile);
}
await rm(dir, {recursive: true});
const L = modules.atlasLib;
const Work = modules.atlasWork.default, Conversation = modules.atlasConversation.default;
const requestId = "a00123456789012";
const boot = {org: {id: "org", name: "Research QA", edition: "Developer Edition", isSandbox: false}, user: {id: "user", name: "Tester"}, people: []};
const settings = {mine: {replyLimit: 100000}, jira: {}};
const intake = () => ({componentType: "Flow", apiName: "Account_Onboarding", goal: "Verify safe account creation", testing: ""});
const form = () => ({mode: "uat", title: "Onboarding acceptance", request: "Cover all branches and security", uat: intake()});
const plan = () => ({
  type: "atlas-uat-plan", requestId, title: "Account onboarding UAT", summary: "User executes account onboarding and rejection checks.",
  environment: "QA Research org only, active Flow v4; isolate records and disable outbound email before execution.",
  scope: "Account entry, child flow, Apex service and async notification.",
  evidence: [{source: "Flow Account_Onboarding v4 retrieved from Research QA", observation: "Calls child flow Account_Validate"}],
  dependencies: [{name: "Account_Validate", version: "4", status: "inspected", evidence: "Retrieved flow"}, {name: "ExternalERP", version: "unknown", status: "inaccessible", evidence: "No external access; integration behavior needs owner confirmation"}],
  limitations: ["External integration version inaccessible; integration test stays blocked until confirmed."],
  prerequisites: ["QA only, confirmed test role and isolated records"], testData: ["Disposable Account named UAT-001"], cleanup: ["User removes disposable account using approved cleanup"],
  coverage: L.UAT_COVERAGE.map((area) => ({area, applicable: true, rationale: `Validate ${area} in the isolated QA process`, testIds: ["UAT-001"]})),
  tests: [{id: "UAT-001", title: "Create a permitted account", role: "Sales rep with Account create, no admin access", preconditions: ["Log into QA as sales rep"], data: ["Account name UAT-001; industry Technology"], steps: [{action: "Open Accounts, choose New, enter UAT-001 and save", expected: "Account detail opens and its onboarding status is Ready"}, {action: "Check processing record after 30 seconds", expected: "Notification status is Complete; no real email was sent"}], expectedResult: "Account is ready without duplicate notification", cleanup: ["Remove isolated record; verify no pending async job"]}],
  findings: [{id: "F1", summary: "Suspected empty-name branch mismatch", evidence: ["Flow branch compares null; empty text normalization is not verified"], testIds: ["UAT-001"], sourcePrompt: "Investigate Account_Onboarding v4 null handling, compare expected required-name behavior and add boundary regression coverage."}],
});
const event = {currentTarget: {dataset: {index: "0"}}};
function setup() {
  const storage = new Map();
  globalThis.sessionStorage = {getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v), removeItem: (k) => storage.delete(k)};
  globalThis.window = {AtlasFiles: files};
  const calls = [], messages = [], downloads = [];
  let state = {}, revision = 0;
  globalThis.uatApex = async (name, args) => {
    calls.push({name, args});
    if (name === "listWrites") return "[]";
    if (name === "conversationPage") return JSON.stringify({rows: [], cursor: null});
    if (name === "getConversation") return JSON.stringify({...form(), id: requestId, status: "Open", changes: [], tickets: [], messages});
    if (name === "getState") return JSON.stringify({revision, data: state});
    if (name === "saveState") { state = JSON.parse(args.stateJson); return ++revision; }
    if (name === "appendMessages") {
      const added = JSON.parse(args.messagesJson).map((m, i) => ({...m, id: `m${messages.length + i}`, recordId: `m${messages.length + i}`, created: new Date().toISOString()}));
      messages.push(...added); return JSON.stringify(added);
    }
    if (name === "addMessage") { messages.push({...args, id: `m${messages.length}`, recordId: `m${messages.length}`}); return "message"; }
    if (name === "startConversationChecked") return requestId;
    if (name === "saveFile") return "068123456789012";
    if (name === "run") return JSON.stringify({rows: []});
    throw Error(`Unexpected Apex ${name}`);
  };
  const link = {click() { downloads.push(this.href); }, removeAttribute() {}};
  const template = {querySelector: (selector) => selector === "a.atlas-download" ? link : null};
  const c = new Conversation(); c.boot = boot; c.settings = settings; c.conversationId = requestId; c.template = template;
  c.convo = {...form(), id: requestId, changes: [], tickets: [], messages};
  const work = new Work(); work.boot = boot; work.settings = settings; work.template = template;
  return {c, work, calls, messages, downloads, storage};
}

test("Work and Salesforce mode choices use the requested five-mode order", async () => {
  const {work} = setup();
  assert.deepEqual(work.modeOptions.map((mode) => mode.displayLabel), ["Source", "Task", "UAT", "Support Tickets", "Files"]);
  const metadata = await readFile(new URL("../salesforce/force-app/main/default/objects/Atlas_Conversation__c/fields/Mode__c.field-meta.xml", import.meta.url), "utf8");
  const document = new DOMParser().parseFromString(metadata, "application/xml");
  const labels = Array.from(document.getElementsByTagName("value"), (value) => value.getElementsByTagName("label")[0].textContent);
  assert.deepEqual(labels, work.modeOptions.map((mode) => mode.displayLabel));
});

test("UAT Salesforce source contains no XML-forbidden literal characters", async () => {
  for (const name of ["atlasLib/uat.js", "atlasLib/prompts.js", "atlasWork/atlasWork.js", "atlasWork/atlasWork.html", "atlasConversation/atlasConversation.js", "atlasConversation/atlasConversation.html"]) {
    const source = await readFile(join(root, name), "utf8");
    const invalid = Array.from(source).filter((character) => {
      const point = character.codePointAt(0);
      return point < 32 && ![9, 10, 13].includes(point) || point === 65534 || point === 65535;
    });
    assert.equal(invalid.length, 0, `${name} must survive Salesforce XML resource transport`);
  }
});

for (const componentType of L.UAT_COMPONENT_TYPES) test(`UAT creation requires complete ${componentType} intake`, () => {
  const value = form(); value.uat.componentType = componentType;
  if (componentType === "Other") {
    assert.throws(() => L.checkUatIntake(value), /What you are testing/);
    value.uat.testing = "Custom approval process";
  }
  assert.equal(L.checkUatIntake(value).componentType, componentType);
  for (const key of ["apiName", "goal"]) assert.throws(() => L.checkUatIntake({...value, uat: {...value.uat, [key]: " "}}));
  assert.throws(() => L.checkUatIntake({...value, request: ""}), /UAT prompt/);
  assert.throws(() => L.checkUatIntake({...value, request: "x".repeat(30001)}), /30,000/);
  assert.throws(() => L.checkUatIntake({...value, uat: {...value.uat, apiName: "x".repeat(256)}}), /255/);
});

test("UAT browser drafts, imported library drafts and start retain intake; successful start resets form", async () => {
  const {work, calls} = setup(); work.connectedCallback(); work.form = form(); work.cacheDraft();
  const restored = new Work(); restored.boot = boot; restored.settings = settings; restored.template = work.template; restored.connectedCallback();
  assert.deepEqual(restored.form, form()); assert.equal(restored.isUat, true);
  assert.equal(restored.modeOptions.find((m) => m.value === "uat").displayLabel, "UAT");
  const downloaded = JSON.parse(restored.draftJSON()); assert.deepEqual(downloaded.uat, intake());
  const imported = new Work(); imported.boot = boot; imported.settings = settings; imported.template = work.template;
  imported.connected = true; imported.pendingDrafts = [downloaded]; await imported.openPendingDraft();
  assert.deepEqual(imported.form.uat, intake());
  await restored.start();
  const start = calls.find((c) => c.name === "startConversationChecked").args;
  assert.deepEqual(JSON.parse(start.conversationJson).uat, intake());
  assert.match(start.prompt, /API name: Account_Onboarding/);
  assert.match(start.prompt, /UAT is read-only research/);
  assert.equal(restored.selectedId, requestId); assert.equal(restored.form.mode, "Source"); assert.equal(restored.form.uat, undefined);
  assert.equal(calls.filter((c) => c.name === "startConversationChecked").length, 1);
});

test("switching modes retains unsent UAT intake but excludes it from a Source start", async () => {
  const {work, calls} = setup(); work.connected = true; work.form = form();
  work.handleMode({target: {value: "Source"}}); assert.deepEqual(work.form.uat, intake());
  work.handleMode({target: {value: "uat"}}); assert.equal(work.isUat, true); assert.deepEqual(work.uat, intake());
  work.handleMode({target: {value: "Source"}}); await work.start();
  const submitted = JSON.parse(calls.find((call) => call.name === "startConversationChecked").args.conversationJson);
  assert.equal(submitted.mode, "Source"); assert.equal(submitted.uat, undefined);
});

test("invalid UAT intake does not create a conversation or lock a pending request", async () => {
  const {work, calls} = setup(); work.connected = true; work.form = {...form(), uat: {...intake(), componentType: "Other"}};
  await work.start();
  assert.match(work.error, /What you are testing/); assert.equal(work.startPending, null);
  assert.ok(!calls.some((c) => c.name === "startConversationChecked"));
  assert.equal(L.validUatDraft({componentType: "Other", apiName: ""}), true);
  assert.equal(L.validUatDraft({apiName: {unsafe: true}}), false);
});

test("UAT start response loss replays the identical intake after browser reload", async () => {
  const {work, calls} = setup(); work.connected = true; work.form = form();
  const original = globalThis.uatApex; let lost = true;
  globalThis.uatApex = async (name, args) => { const reply = await original(name, args); if (name === "startConversationChecked" && lost) { lost = false; throw Error("reply lost"); } return reply; };
  await work.start(); assert.match(work.error, /reply lost/);
  const reloaded = new Work(); reloaded.boot = boot; reloaded.settings = settings; reloaded.template = work.template; reloaded.connectedCallback();
  assert.ok(reloaded.startPending); await reloaded.start();
  const starts = calls.filter((c) => c.name === "startConversationChecked"); assert.equal(starts.length, 2);
  assert.deepEqual(starts[0].args, starts[1].args); assert.equal(reloaded.selectedId, requestId);
});

test("initial prompt and reminder teach the same complete read-only methodology without write contracts", () => {
  for (const fn of [L.firstPrompt, L.rulesReminder]) {
    const value = fn({conversation: {...form(), id: requestId}, boot, mine: settings.mine, jira: {writeEnabled: true, externalCredential: "Live"}});
    for (const pattern of [/atlas-uat-plan/, /atlas-response-part/, /active versus draft Flow versions/, /protected packages/, /truncated results/, /clarifying questions BEFORE/, /negative\/edge cases/, /asynchronous completion/, /FAILED OR BLOCKED TEST FOLLOWUP/, /Source-mode repair prompt/, /API name: Account_Onboarding/]) assert.match(value, pattern);
    for (const pattern of [/CHANGE SALESFORCE: back up/, /WRITE JIRA:/, /TICKETS: atlas-tickets/, /Every message type works/]) assert.doesNotMatch(value, pattern);
  }
  assert.equal(L.MODE_LABELS["support-tickets"], "Support Tickets"); assert.ok(L.firstPrompt({conversation: {mode: "support-tickets", request: "Support", title: "Ticket"}, boot, mine: settings.mine, jira: {}}).includes("SUPPORT TICKETS: INVESTIGATE SUPPORT"));
});

test("plan conversion is deterministic, bounded and has real initially unchecked Word controls", async () => {
  const p = plan(), artifact = L.uatPlanToArtifact(p, requestId);
  assert.deepEqual(artifact, L.uatPlanToArtifact(JSON.parse(JSON.stringify(p)), requestId));
  assert.equal(artifact.kind, "docx");
  const checkboxes = artifact.blocks.filter((b) => b.type === "checklist").flatMap((b) => b.items);
  assert.ok(checkboxes.length >= 11); assert.ok(checkboxes.every((c) => c.checked === false));
  for (const id of ["UAT-001.1", "UAT-001.2", "UAT-001"]) for (const status of ["Pass", "Fail", "Blocked"]) assert.ok(checkboxes.some((c) => c.text === `${id} ${status}`));
  assert.ok(artifact.blocks.some((b) => b.text?.includes("Actual result / evidence")));
  assert.match(L.uatRepairPrompts(p)[0].text, /suspected defect, not a confirmed diagnosis/);
  assert.match(L.uatRepairPrompts(p)[0].text, /No repair is authorized/);
  files.checkFiles({artifacts: [artifact]});
  const output = await files.buildFile(artifact);
  const xml = strFromU8(unzipSync(output.bytes)["word/document.xml"]);
  const doc = new DOMParser().parseFromString(xml, "application/xml");
  const nodes = Array.from(doc.getElementsByTagNameNS("http://schemas.microsoft.com/office/word/2010/wordml", "checkbox"));
  assert.equal(nodes.length, checkboxes.length);
  for (const node of nodes) assert.equal(node.getElementsByTagNameNS("http://schemas.microsoft.com/office/word/2010/wordml", "checked")[0].getAttribute("w14:val"), "0");
  assert.match(xml, /UAT-001.1/); assert.match(xml, /Source-mode/);
});

test("plans reject malformed shapes, mismatched IDs, invented outcomes and excess sizes", () => {
  const cases = [
    (p) => p.requestId = "other", (p) => p.artifacts = [{kind: "xlsx"}], (p) => p.tests[0].status = "Pass",
    (p) => p.tests[0].steps[0].checked = true, (p) => p.tests[0].steps[0].expected = "", (p) => p.tests.push(p.tests[0]),
    (p) => p.coverage[0].testIds = ["MISSING"], (p) => p.coverage[1].area = p.coverage[0].area,
    (p) => p.dependencies[0].status = "complete", (p) => p.evidence = [], (p) => p.findings[0].evidence = [],
    (p) => p.findings[0].sourcePrompt = "", (p) => p.tests[0].steps[0].action = "x".repeat(1501),
  ];
  for (const mutate of cases) { const p = plan(); mutate(p); assert.throws(() => L.uatPlanToArtifact(p, requestId)); }
  const huge = plan(); huge.tests = Array.from({length: 40}, (_, i) => ({...huge.tests[0], id: `T${i}`, steps: Array.from({length: 10}, () => ({action: "Do", expected: "See"}))}));
  assert.throws(() => L.uatPlanToArtifact(huge, requestId), /200 total steps/);
  const tooManyBlocks = plan();
  tooManyBlocks.tests = Array.from({length: 40}, (_, i) => ({...tooManyBlocks.tests[0], id: i === 0 ? "UAT-001" : `TEST-${i}`, steps: Array.from({length: 4}, () => ({action: "Open", expected: "Visible"}))}));
  assert.throws(() => L.uatPlanToArtifact(tooManyBlocks, requestId), /500 Word blocks/);
});

test("maximum-sized plan fields produce valid Word blocks without truncation", () => {
  const p = plan();
  p.findings[0].summary = "s".repeat(4000); p.findings[0].sourcePrompt = "p".repeat(12000); p.findings[0].evidence = Array.from({length: 20}, () => "e".repeat(4000));
  p.evidence[0].source = "s".repeat(1000); p.evidence[0].observation = "o".repeat(4000);
  p.dependencies[0].evidence = "d".repeat(4000); p.tests[0].cleanup = ["c".repeat(4000)]; p.coverage[0].rationale = "r".repeat(4000);
  const artifact = L.uatPlanToArtifact(p, requestId); files.checkFiles({artifacts: [artifact]});
  const output = JSON.stringify(artifact); assert.match(output, /o{4000}/); assert.equal((output.match(/e{4000}/g) || []).length >= 15, true);
  p.summary = "Invalid\u0001 control"; assert.throws(() => L.uatPlanToArtifact(p, requestId), /XML control/);
});

test("long plans use validated existing multipart envelopes without losing text", () => {
  const p = plan(); p.summary = "Large detailed summary. ".repeat(150);
  const serialized = JSON.stringify(p), chunks = serialized.match(/[\s\S]{1,2500}/g);
  const paste = chunks.map((text, index) => "```json\n" + JSON.stringify({type: "atlas-response-part", id: "uat-plan-1", part: index + 1, total: chunks.length, text}) + "\n```").join("\n");
  assert.deepEqual(L.parseAgentJSON(paste), p);
  assert.deepEqual(L.uatPlanToArtifact(L.parseAgentJSON(paste), requestId), L.uatPlanToArtifact(p, requestId));
  assert.throws(() => L.parseAgentJSON(paste.replace('"part":1', '"part":2')), /twice/);
});

test("UAT routing rejects every mutation and arbitrary files before history or network activity", async () => {
  for (const type of ["atlas-backup", "atlas-change", "atlas-assign", "atlas-tickets", "atlas-jira-write", "atlas-jira-refresh", "atlas-files", "atlas-users", "atlas-context", "atlas-support-ticket-report", "atlas-deploy", "atlas-run-tests"]) {
    const {c, calls} = setup(); c.paste = JSON.stringify({type, requestId, artifacts: [{kind: "docx", name: "bypass.docx", blocks: []}]});
    await c.processPaste(); assert.match(c.problem.text, /UAT cannot process/); assert.equal(calls.length, 0, type);
  }
  for (const op of ["jira", "tickets", "local-tickets", "users", "people", "execute", "run-tests"]) assert.throws(() => L.validateUatMessageType({type: "atlas-request", requests: [{op}]}), /does not allow/);
  for (const op of L.UAT_READ_OPS) L.validateUatMessageType({type: "atlas-request", requests: [{op, ...(op === "rest" ? {path: "/limits"} : {})}]});
  for (const path of ["/tooling/executeAnonymous?anonymousBody=delete+x", "/actions/custom/flow/Run", "/sobjects/Account/001123456789012", "/limits?method=POST", "/limits?_HttpMethod=DELETE", "/services/data/v67.0/../actions", "/%71uery?q=select"]) assert.throws(() => L.validateUatMessageType({type: "atlas-request", requests: [{op: "rest", path}]}), /UAT REST/);
  for (const path of ["/services/data/v67.0/tooling/query?q=SELECT+Id+FROM+ApexClass", "/sobjects/Account/describe", "/tooling/query/cursor-1", "/ui-api/record-ui/001123456789012?modes=View"]) L.validateUatMessageType({type: "atlas-request", requests: [{op: "rest", path}]});
  assert.throws(() => L.validateUatMessageType({type: "atlas-request", requests: [{op: "rest", method: "POST"}]}), /write/);
  const {c, calls} = setup();
  for (const method of ["backup", "proposeChange", "reviewAssignments", "checkTickets", "reviewJiraWrite", "prepareSupportTicketEscalation", "readContext"]) await assert.rejects(() => c[method]({}), /UAT cannot/);
  await c.saveTickets(); assert.match(c.problem.text, /UAT cannot/);
  await c.finishAssignments(true); assert.match(c.problem.text, /UAT cannot/);
  await assert.rejects(() => c.orgWrite(() => { throw Error("must not run"); }), /UAT cannot/);
  assert.equal(calls.length, 0);
});

test("UAT questions and permitted read-only research remain usable", async () => {
  const {c, calls} = setup(); c.connectHistory();
  c.paste = JSON.stringify({type: "atlas-questions", questions: [{id: "Q1", question: "Confirm QA version?"}]});
  await c.processPaste(); assert.equal(c.problem, null); assert.equal(c.questions[0].question, "Confirm QA version?");
  c.questions[0].answer = "QA v4"; await c.sendAnswers(); assert.match(c.outgoing.text, /UAT REQUEST ID:/); assert.match(c.outgoing.text, /UAT is read-only/);
  await c.runRequests({type: "atlas-request", requests: [{id: "q1", op: "soql", query: "SELECT Id FROM Account LIMIT 1"}]});
  assert.ok(calls.some((call) => call.name === "run")); assert.match(c.outgoing.text, /UAT is read-only/);
  await c.outbox.flush(); c.unsubscribeHistory?.();
});

test("a saved UAT plan reloads through Files and downloads/saves the same validated Word artifact", async () => {
  const {c, calls, messages, downloads} = setup(); c.connectHistory(); c.paste = JSON.stringify(plan());
  await c.processPaste(); assert.equal(c.problem, null); assert.equal(c.uatPlan.tests[0].id, "UAT-001");
  assert.ok(messages.some((m) => m.kind === "atlas-uat-plan"));
  assert.equal(c.fileReview[0].kind, "docx");
  const expected = c.artifactsJson;
  const reloaded = new Conversation(); reloaded.boot = boot; reloaded.settings = settings; reloaded.conversationId = requestId; reloaded.template = c.template;
  await reloaded.load(true); assert.equal(reloaded.problem, undefined); assert.equal(reloaded.isUat, true); assert.deepEqual(reloaded.convo.uat, intake()); assert.equal(reloaded.artifactsJson, expected);
  await reloaded.downloadArtifact(event); assert.equal(reloaded.problem, null); assert.equal(downloads.length, 1);
  await reloaded.saveToSalesforce(event); assert.equal(reloaded.problem, null);
  const saved = calls.find((call) => call.name === "saveFile").args; assert.equal(saved.parentId, requestId); assert.equal(saved.fileName, "UAT-plan.docx");
  const xml = strFromU8(unzipSync(new Uint8Array(Buffer.from(saved.base64, "base64")))["word/document.xml"]);
  assert.match(xml, /w14:checkbox/); assert.match(reloaded.banner.url, /068123456789012/);
  await assert.rejects(() => reloaded.listFiles({type: "atlas-files", artifacts: [{kind: "xlsx"}]}), /UAT plan/);
  reloaded.artifactsJson = JSON.stringify([{kind: "xlsx", name: "evil.xlsx"}]); assert.equal(reloaded.artifactAt(event).kind, "docx");
  assert.ok(!calls.some((call) => ["applyBatch", "prepareWrite", "startBackup", "decideConfirmed"].includes(call.name)));
  c.unsubscribeHistory?.();
});

test("reload finds a UAT plan beyond the newest history page and exposes older plan downloads", async () => {
  const {c, calls} = setup(); const original = globalThis.uatApex;
  const stored = {id: "old-plan", recordId: "old-plan", kind: "atlas-uat-plan", direction: "From Agent", hasFullBody: true};
  globalThis.uatApex = async (name, args) => {
    if (name === "getConversation") return JSON.stringify({...form(), id: requestId, changes: [], tickets: [], messages: [{id: "new-result", kind: "uat-results", direction: "To Agent", body: "Failed UAT-001"}], messageCursor: "older"});
    if (name === "messagePage") { calls.push({name, args}); return JSON.stringify({messages: [stored], cursor: null}); }
    if (name === "getMessage") return JSON.stringify(plan());
    return original(name, args);
  };
  await c.load(true); assert.equal(c.uatPlan.title, plan().title); assert.ok(calls.some((call) => call.name === "messagePage"));
  c.convo = {...c.convo, messages: [stored]};
  assert.equal(c.history[0].isUatPlan, true); await c.openUatPlan({currentTarget: {dataset: {id: stored.id}}}); assert.equal(c.problem, null);
});

test("workspace-restored history preserves original plan identity without relaxing live paste validation", async () => {
  const {c, messages, calls, downloads} = setup();
  const oldPlan = {...plan(), requestId: "a00999999999999"};
  messages.push({id: "restored-plan", recordId: "restored-plan", direction: "From Agent", kind: "atlas-uat-plan", body: JSON.stringify(oldPlan)});
  messages.push({id: "unsafe-file", recordId: "unsafe-file", direction: "From Agent", kind: "atlas-files", body: JSON.stringify({type: "atlas-files", artifacts: [{kind: "xlsx", name: "ignore.xlsx"}]})});
  await c.load(true); assert.equal(c.uatPlan.requestId, oldPlan.requestId); assert.match(c.uatPlanProvenance, /recovered from conversation a00999999999999/);
  assert.equal(c.fileReview[0].kind, "docx"); assert.equal(c.fileReview.length, 1);
  await c.downloadArtifact(event); assert.equal(c.problem, null); assert.equal(downloads.length, 1);
  await c.saveToSalesforce(event); assert.equal(c.problem, null);
  const saved = calls.find((call) => call.name === "saveFile");
  assert.equal(saved.args.parentId, requestId); assert.equal(saved.args.fileName, "UAT-plan.docx");
  const xml = strFromU8(unzipSync(new Uint8Array(Buffer.from(saved.args.base64, "base64")))["word/document.xml"]);
  assert.match(xml, /a00999999999999/);
  const before = calls.length; c.paste = JSON.stringify(oldPlan); await c.processPaste();
  assert.match(c.problem.text, /different conversation/); assert.equal(calls.length, before);
  await assert.rejects(() => c.listFiles(oldPlan), /exact requestId/);
  await assert.rejects(() => c.restoreUatHistory(messages[1], messages[1].body), /Only a saved UAT plan/);
});

test("failed-test followup persists its evidence and context without requiring a replacement plan", async () => {
  const {c, calls, messages} = setup();
  c.uatResults = {testIds: "UAT-001.2", expected: "Complete within 30 seconds", actual: "Blocked: still queued", evidence: "QA v4, sales rep, 2026-10-20 09:12; screenshot described: status Queued; no secrets"};
  c.draftLoaded = true; await c.persistDraft(); await c.sendUatResults();
  assert.equal(c.problem, null); assert.match(c.outgoing.text, /UAT-001.2/); assert.match(c.outgoing.text, /user-reported/); assert.match(c.outgoing.text, /Source-mode repair prompt/);
  assert.equal(c.outgoing.state, "saved"); assert.ok(messages.some((m) => m.kind === "uat-results"));
  const reloaded = new Conversation(); reloaded.boot = boot; reloaded.settings = settings; reloaded.conversationId = requestId; reloaded.template = c.template;
  await reloaded.load(true); assert.deepEqual(reloaded.uatResults, c.uatResults); assert.match(reloaded.outgoing.text, /UAT-001.2/);
  assert.ok(!calls.some((call) => ["run", "applyBatch", "prepareWrite", "decideConfirmed"].includes(call.name)), "Reporting results never executes a test or a repair");
  assert.throws(() => L.uatFailureReport({...c.uatResults, actual: ""}, requestId), /Actual results/);
  assert.throws(() => L.uatFailureReport({...c.uatResults, evidence: "x".repeat(8001)}, requestId), /8,000/);
});

test("UAT recovery discards stale mutation approvals and never polls deployments", async () => {
  const {c, calls} = setup(); const original = globalThis.uatApex;
  globalThis.uatApex = async (name, args) => {
    if (name === "getState") return JSON.stringify({revision: 1, data: {ticketReview: {batch: {}}, assignmentReview: [{}], assignmentDecision: {approve: true}, identities: [{alias: "me"}], refreshRequest: {keys: ["A-1"]}}});
    if (name === "getConversation") return JSON.stringify({...form(), id: requestId, changes: [{id: "bad", status: "Deploying"}], tickets: [], messages: []});
    return original(name, args);
  };
  await c.load(true);
  assert.equal(c.ticketReview, null); assert.equal(c.assignmentReview, null); assert.deepEqual(c.identities, []); assert.equal(c.refreshRequest, null); assert.deepEqual(c.jiraWrites, []);
  assert.ok(!calls.some((call) => call.name === "deployStatus"));
});
