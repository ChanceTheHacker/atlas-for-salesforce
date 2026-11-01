import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const temp = await mkdtemp(join(tmpdir(), "atlas-jira-ui-"));
const lib = {};
for (const name of ["atlasTeam", "atlasTickets", "atlasJiraReview"]) {
  const outfile = join(temp, `${name}.mjs`);
  await build({
    entryPoints: [join(root, name, `${name}.js`)], bundle: true, platform: "node", format: "esm", outfile,
    plugins: [{ name: "lightning-boundaries", setup(b) {
      b.onResolve({ filter: /^lwc$|^lightning\/|^@salesforce\// }, ({ path }) => ({ path, namespace: "platform" }));
      b.onLoad({ filter: /.*/, namespace: "platform" }, ({ path }) => ({ contents:
        path === "lwc" ? "export class LightningElement { dispatchEvent() {} } export const api = () => {};" :
        path.startsWith("@salesforce/apex/") ? `export default (...args) => globalThis.atlasJiraApex(${JSON.stringify(path.split(".").at(-1))}, ...args);` :
        path.startsWith("lightning/") ? "export const loadScript = async () => {};" : "export default 'resource';"
      }));
      b.onResolve({ filter: /^c\/atlasLib$/ }, () => ({ path: "lib", namespace: "test-lib" }));
      b.onLoad({ filter: /.*/, namespace: "test-lib" }, () => ({ contents: `
        export { jiraReviewManager } from ${JSON.stringify(join(root, "atlasLib", "settings.js"))};
        export const DEFAULT_REPLY_LIMIT = 14000;
        export const TEST_LEVELS = [];
        export const describeMapping = () => [];
        export const downloadFile = () => {};
        export const errorMessage = (e) => e?.message || String(e);
        export const parseMapping = () => ({});
        export const replyLimit = (v) => Number(v) || 14000;
        export const exportCSV = () => "";
        export const importRows = () => [];
        export const localDate = () => "2026-10-19";
        export const parseCSV = () => [];
        export const updateText = () => "";
        export const planningState = () => ({ lane: "Backlog", blockerNote: "", dependencies: [], followUp: "", snooze: "" });
        export const planningLane = () => "Backlog";
        export const reminderText = () => "";
        export const epicExportPlan = () => ({});
        export const refreshJql = () => "";
        export const legacyChunks = () => [];
        export const rawExportCSV = () => "";
        export const reviewImportRows = () => [];
      `, resolveDir: root }));
      b.onResolve({ filter: /^c\/atlasStorage$/ }, () => ({ path: "storage", namespace: "test-storage" }));
      b.onLoad({ filter: /.*/, namespace: "test-storage" }, () => ({ contents: "export const restoreLibrary = async () => ({}); export const readLibrary = async () => ({}); export const inOrder = (a) => a;" }));
      b.onLoad({ filter: /\/atlas(?:Team|Tickets|JiraReview)\/atlas(?:Team|Tickets|JiraReview)\.js$/ }, async ({ path }) => ({
        contents: (await readFile(path, "utf8")).replace(/@api\s+/g, ""), loader: "js",
      }));
    }}],
  });
  lib[name] = (await import(outfile)).default;
}
const settingsOut = join(temp, "settings.mjs");
await build({ entryPoints: [join(root, "atlasLib", "settings.js")], bundle: true, platform: "node", format: "esm", outfile: settingsOut });
lib.settings = await import(settingsOut);
const teamHtml = await readFile(join(root, "atlasTeam", "atlasTeam.html"), "utf8");
const ticketsHtml = await readFile(join(root, "atlasTickets", "atlasTickets.html"), "utf8");
const reviewHtml = await readFile(join(root, "atlasJiraReview", "atlasJiraReview.html"), "utf8");
await rm(temp, { recursive: true });

globalThis.CustomEvent ||= class CustomEvent { constructor(type, options = {}) { this.type = type; this.detail = options.detail; } };

test("settings keep legacy CSV defaults and normalize independent Jira access switches", () => {
  const manual = lib.settings.readSettings({});
  assert.equal(manual.jira.apiVersion, "3");
  assert.equal(manual.jira.readEnabled, false);
  assert.equal(manual.jira.writeEnabled, false);
  assert.equal(manual.jira.externalCredential, "");
  const writeOnly = lib.settings.readSettings({ settings: { jira: JSON.stringify({
    siteUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", apiVersion: "2", readEnabled: "true", writeEnabled: true,
  }) } });
  assert.equal(writeOnly.jira.readEnabled, false, "truthy strings must not enable reads");
  assert.equal(writeOnly.jira.writeEnabled, true);
  assert.equal(writeOnly.jira.apiVersion, "2");
  assert.equal(lib.settings.readSettings({ settings: { jira: JSON.stringify({ apiVersion: "5" }) } }).jira.apiVersion, "3");
  assert.match(teamHtml, /Do not enter a password, token, or other secret/);
  assert.match(teamHtml, /scoped gateway path in the optional API base URL/);
  assert.match(teamHtml, /Atlas Jira Admin permission set/);
});

test("review manager resolves only an exact active identity of the explicitly confirmed Jira type", () => {
  const person = { id: "manager-1", name: "Casey", active: true, jiraId: "cloud:casey" };
  const jira = { reviewManagerPersonId: person.id, reviewManagerIdentityType: "accountId", apiVersion: "3" };
  const resolve = (settings = jira, people = [person]) => lib.settings.jiraReviewManager(settings, people);
  assert.equal(resolve().ready, true);
  assert.equal(resolve().jiraId, "cloud:casey");
  assert.equal(resolve({}).status, "unconfigured");
  assert.equal(resolve(jira, [{ ...person, id: "other" }]).status, "unavailable", "matching names cannot replace missing references");
  for (const [changes, status] of [[{ active: false }, "inactive"], [{ active: undefined }, "inactive"], [{ jiraId: "" }, "missing_jira_id"], [{ identityWarning: "SSO mismatch" }, "identity_warning"]]) {
    const result = resolve(jira, [{ ...person, ...changes }]);
    assert.equal(result.status, status);
    assert.equal(result.ready, false);
    assert.equal(result.jiraId, "", "an unresolved identity cannot accidentally be used for routing");
  }
  assert.equal(resolve({ ...jira, reviewManagerIdentityType: "" }).status, "unconfirmed_identity");
  assert.equal(resolve({ ...jira, apiVersion: "2" }).status, "identity_type_mismatch");
  const dc = resolve({ ...jira, apiVersion: "2", reviewManagerIdentityType: "name" }, [{ ...person, jiraId: "casey.username" }]);
  assert.equal(dc.ready, true);
  assert.equal(dc.identityType, "name");
  assert.equal(dc.jiraId, "casey.username");
  assert.equal(resolve({ ...jira, apiVersion: "unknown" }).ready, false);
  const restored = lib.settings.readSettings({ settings: { jira: JSON.stringify({ ...jira, priorities: "Urgent, Normal", customSetting: "kept" }) } });
  assert.equal(restored.jira.reviewManagerPersonId, person.id);
  assert.equal(restored.jira.reviewManagerIdentityType, "accountId");
  assert.equal(restored.jira.customSetting, "kept");
  assert.equal(lib.settings.readSettings({}).jira.reviewManagerPersonId, "");
});

test("person Manager role fails closed on duplicates, legacy conflicts, and unconfirmed replacement identities", () => {
  const manager = { id: "manager-1", name: "Casey", active: true, isManager: true, jiraId: "cloud:casey", jiraIdentityType: "accountId" };
  const resolve = (people = [manager], jira = {}) => lib.settings.jiraReviewManager(jira, people);
  assert.equal(resolve().ready, true);
  assert.equal(resolve().personId, manager.id);
  assert.equal(resolve([{ ...manager, jiraIdentityType: "" }]).status, "unconfirmed_identity");
  assert.equal(resolve([{ ...manager, jiraIdentityType: "" }], { reviewManagerPersonId: manager.id, reviewManagerIdentityType: "accountId" }).status,
    "unconfirmed_identity", "old settings cannot resurrect a cleared person confirmation");
  for (const [people, jira] of [
    [[manager, { ...manager, id: "second", active: false }], {}],
    [[manager], { reviewManagerPersonId: "missing-person", reviewManagerIdentityType: "accountId" }],
    [[manager, manager], {}],
  ]) {
    const result = resolve(people, jira);
    assert.equal(result.status, "ambiguous");
    assert.equal(result.ready, false);
    assert.equal(result.personId, "");
    assert.equal(result.jiraId, "");
  }
  assert.equal(resolve([{ ...manager, isManager: false, aliases: ["manager"] }]).status, "unconfigured");
  assert.equal(resolve([{ ...manager, active: false }]).status, "inactive");
  assert.equal(resolve([{ ...manager, identityWarning: "SSO mismatch" }]).status, "identity_warning");
  assert.equal(resolve([manager], { apiVersion: "2" }).status, "identity_type_mismatch");
});

test("People saves Manager and confirmed Jira identity through the person checkbox payload", async () => {
  const calls = [];
  const previous = globalThis.atlasJiraApex;
  globalThis.atlasJiraApex = async (name, args) => { calls.push({ name, args }); };
  try {
    const team = new lib.atlasTeam();
    team.boot = { people: [{ id: "me", name: "Me", aliases: [], isMe: true }] };
    team.jiraCapabilities = { canConfigure: false };
    team.addPerson();
    assert.equal(team.person.isManager, false);
    assert.equal(team.person.jiraIdentityType, "");
    team.handlePerson({ target: { name: "name" }, detail: { value: "Casey" } });
    team.handlePerson({ target: { name: "jiraId" }, detail: { value: "cloud:casey" } });
    team.handlePerson({ target: { name: "isManager", type: "checkbox" }, detail: { checked: true, value: false } });
    team.handlePerson({ target: { name: "jiraIdentityType" }, detail: { value: "accountId" } });
    await team.submitPerson();
    assert.equal(team.error, null);
    assert.equal(team.person, null);
    assert.deepEqual(calls.map((call) => call.name), ["savePerson"], "person changes do not write Jira settings or send Jira requests");
    assert.deepEqual(JSON.parse(calls[0].args.personJson), {
      id: null, name: "Casey", jiraId: "cloud:casey", jiraIdentityType: "accountId", isManager: true,
      aliases: [], userId: null, managerId: "me", active: true,
    });
    team.boot = { people: [{ id: "manager-1", name: "Casey", aliases: ["CJ"], version: 4,
      isManager: true, jiraId: "cloud:casey", jiraIdentityType: "accountId", active: true }] };
    team.editPerson({ currentTarget: { dataset: { id: "manager-1" } } });
    team.handlePerson({ target: { name: "isManager", type: "checkbox" }, detail: { checked: false, value: true } });
    team.handlePerson({ target: { name: "jiraIdentityType" }, detail: { value: "" } });
    await team.submitPerson();
    const cleared = JSON.parse(calls.at(-1).args.personJson);
    assert.equal(cleared.isManager, false);
    assert.equal(cleared.jiraIdentityType, "");
    assert.equal(cleared.version, 4);
    assert.deepEqual(cleared.aliases, ["CJ"]);
  } finally { globalThis.atlasJiraApex = previous; }
});

test("People editor and roles use the legacy manager only when no explicit manager exists", () => {
  const team = new lib.atlasTeam();
  const legacy = { id: "legacy", name: "Casey", aliases: [], active: true, jiraId: "casey", isMyReport: true };
  team.boot = { people: [legacy] };
  team.settings = { jira: { reviewManagerPersonId: "legacy", reviewManagerIdentityType: "name", apiVersion: "2" } };
  team.editPerson({ currentTarget: { dataset: { id: "legacy" } } });
  assert.equal(team.person.isManager, true);
  assert.equal(team.person.jiraIdentityType, "name");
  assert.equal(team.rows[0].role, "My direct report · Manager");
  const cached = team.rows;
  assert.equal(team.rows, cached);
  team.settings = { jira: {} };
  assert.equal(team.rows[0].role, "My direct report", "legacy settings changes invalidate cached role labels");
  team.settings = { jira: { reviewManagerPersonId: "legacy", reviewManagerIdentityType: "name" } };
  team.boot = { people: [legacy, { id: "explicit", name: "Morgan", aliases: [], isManager: true, active: false, jiraIdentityType: "accountId" }] };
  team.editPerson({ currentTarget: { dataset: { id: "legacy" } } });
  assert.equal(team.person.isManager, false, "even an inactive explicit manager supersedes the legacy choice");
  assert.equal(team.person.jiraIdentityType, "");
  assert.equal(team.rows.find((p) => p.id === "legacy").role, "My direct report");
  team.editPerson({ currentTarget: { dataset: { id: "explicit" } } });
  assert.equal(team.person.isManager, true);
  assert.equal(team.person.jiraIdentityType, "accountId");
  assert.equal(team.rows.find((p) => p.id === "explicit").activeText, "No");
  team.boot = { people: [{ ...legacy, jiraIdentityType: "accountId" }] };
  team.editPerson({ currentTarget: { dataset: { id: "legacy" } } });
  assert.equal(team.person.jiraIdentityType, "accountId", "a person's confirmed identity takes precedence over the legacy fallback");
});

test("People shows the active manager with other roles and no separate Jira manager selector", () => {
  const team = new lib.atlasTeam();
  team.settings = { jira: { apiVersion: "3" } };
  const manager = { id: "manager", name: "Morgan", aliases: [], isManager: true, active: true, jiraId: "cloud:morgan", jiraIdentityType: "accountId", isMe: true };
  team.boot = { people: [manager] };
  assert.equal(team.rows[0].role, "Me · Manager");
  assert.equal(team.rows[0].activeText, "Yes");
  team.boot = { people: [{ ...manager, isMe: false, isMyReport: true }] };
  assert.equal(team.rows[0].role, "My direct report · Manager");
  const peopleSection = teamHtml.slice(teamHtml.indexOf('>People</h3>'), teamHtml.indexOf('<div class="atlas-grid-2">'));
  assert.match(peopleSection, /\{reviewManagerStatus\}/);
  assert.match(peopleSection, /type="checkbox" name="isManager" label="Manager" checked=\{person.isManager\} onchange=\{handlePerson\} disabled=\{busy\}/);
  assert.match(peopleSection, /name="jiraIdentityType"[^>]*value=\{person.jiraIdentityType\}[^>]*onchange=\{handlePerson\} disabled=\{busy\}/);
  assert.match(peopleSection, /name="jiraId"[^>]*>[\s\S]*?name="jiraIdentityType"[^>]*>[\s\S]*?<\/div>/);
  assert.match(peopleSection, /Saving a person sends nothing to Jira/);
  assert.doesNotMatch(teamHtml, /name="reviewManagerPersonId"|name="reviewManagerIdentityType"|Support Tickets review manager/);
  assert.equal(team.reviewManagerOptions, undefined);
  assert.deepEqual(team.jiraIdentityOptions.map((option) => option.value), ["", "accountId", "name"]);
  assert.equal(lib.settings.jiraReviewManager(team.jira, team.people).ready, true);
  assert.match(team.reviewManagerStatus, /Morgan/);
});

test("changing a person's Jira ID clears confirmation for typed, SSO, and linked-user values", () => {
  const team = new lib.atlasTeam();
  const person = { id: "manager", name: "Morgan", aliases: [], active: true, isManager: true,
    jiraId: "old", jiraIdentityType: "accountId", ssoId: "new" };
  team.boot = { people: [person] };
  const edit = () => team.editPerson({ currentTarget: { dataset: { id: "manager" } } });
  edit();
  team.handlePerson({ target: { name: "jiraId" }, detail: { value: "old" } });
  assert.equal(team.person.jiraIdentityType, "accountId", "an unchanged ID keeps its confirmation");
  team.handlePerson({ target: { name: "jiraId" }, detail: { value: "new" } });
  assert.equal(team.person.jiraIdentityType, "");
  edit();
  team.useSso();
  assert.equal(team.person.jiraId, "new");
  assert.equal(team.person.jiraIdentityType, "");
  edit();
  team.settings = { identity: { ssoField: "FederationIdentifier" } };
  team.userResults = [{ id: "user", userName: "Morgan", ssoId: "new" }];
  team.pickUser({ preventDefault() {}, currentTarget: { dataset: { id: "user" } } });
  assert.equal(team.person.jiraId, "new");
  assert.equal(team.person.jiraIdentityType, "");
});

test("saving manual and live Jira settings omits stale legacy manager keys without changing connection access", async () => {
  const calls = [];
  const previous = globalThis.atlasJiraApex;
  globalThis.atlasJiraApex = async (name, args) => {
    calls.push({ name, args });
    if (name === "capabilities") return JSON.stringify({ connected: true, canConfigure: false });
  };
  try {
    const team = new lib.atlasTeam();
    team.template = { querySelector: () => ({ reportValidity: () => true }) };
    for (const connection of [{}, { namedCredential: "Existing_NC", externalCredential: "Existing_EC", siteUrl: "https://jira.example", readEnabled: true, writeEnabled: true, connectionRevision: "keep-this" }]) {
      team.settings = { jira: { ...connection, reviewManagerPersonId: "legacy", reviewManagerIdentityType: "accountId", customOption: { keep: true } } };
      team.jiraCapabilities = { canConfigure: false };
      team.handleJira({ target: { name: "projectKey" }, detail: { value: " abc " } });
      assert.equal(team.jiraConnectionDirty, false);
      assert.equal(team.jiraSaveDisabled, false);
      await team.saveJira();
      assert.equal(team.error, null);
      const saved = JSON.parse(calls.filter((call) => call.name === "saveSetting").at(-1).args.data);
      assert.equal(Object.hasOwn(saved, "reviewManagerPersonId"), false);
      assert.equal(Object.hasOwn(saved, "reviewManagerIdentityType"), false);
      assert.equal(saved.projectKey, "ABC");
      assert.deepEqual(saved.customOption, { keep: true });
      assert.equal(saved.connectionRevision, connection.connectionRevision);
      assert.equal(team.jira.reviewManagerPersonId, "legacy", "local legacy fallback remains until refreshed by the server");
      assert.equal(team.jira.reviewManagerIdentityType, "accountId");
      assert.equal(team.jiraDirty, false);
    }
    assert.ok(calls.every((call) => ["saveSetting", "capabilities"].includes(call.name)), "settings never call Jira or send a mutation");
  } finally { globalThis.atlasJiraApex = previous; }
});

test("Team settings distinguish manual, write-only, backend connection status, and the saved-only read test", async () => {
  const calls = [];
  const previous = globalThis.atlasJiraApex;
  let canConfigure = true;
  globalThis.atlasJiraApex = async (name, ...args) => {
    calls.push({ name, args });
    if (name === "capabilities") return JSON.stringify({ connected: true, readEnabled: false, writeEnabled: true, mode: "live", canConfigure });
    if (name === "connectionTest") return JSON.stringify({ ok: true, message: "Jira authenticated this user.", writePermissionVerified: false });
    if (name === "saveSetting") return undefined;
    return [];
  };
  try {
    const team = new lib.atlasTeam();
    team.settings = { jira: {} };
    assert.equal(team.jiraManualMode, true);
    assert.equal(team.jiraModeLabel, "Manual CSV mode");
    team.settings = { jira: { siteUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", writeEnabled: true } };
    assert.equal(team.jira.readEnabled, false);
    assert.equal(team.jira.writeEnabled, true);
    assert.equal(team.jiraTestDisabled, true);
    assert.match(team.jiraConnectionSummary, /Enable Jira reads/);
    await team.loadJiraCapabilities();
    assert.match(team.jiraCapabilitySummary, /Saved Jira credentials are configured/);
    assert.match(team.jiraCapabilitySummary, /does not test a network connection/i);

    team.settings = { jira: { siteUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", readEnabled: true, writeEnabled: false } };
    await team.loadJiraCapabilities();
    assert.equal(team.jiraTestDisabled, false);
    await team.testJiraConnection();
    const testCall = calls.find((call) => call.name === "connectionTest");
    assert.deepEqual(testCall.args, [], "the test sends no form fields and relies on saved settings");
    assert.match(team.jiraTestStatus, /Connection test passed/);
    assert.match(team.jiraTestStatus, /Write permission was not tested/);

    canConfigure = false;
    team.settings = { jira: { siteUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", apiVersion: "3",
      apiBaseUrl: "", readEnabled: true, writeEnabled: false, connectionRevision: 17, projectKey: "ABC", priorities: "High, Low", defaultPriority: "High" } };
    await team.loadJiraCapabilities();
    team.jira = { ...team.jira, priorities: "Urgent, Normal" };
    assert.equal(team.jiraConnectionDirty, false, "CSV priority changes leave the protected connection snapshot intact");
    assert.equal(team.jiraSaveDisabled, false, "CSV settings remain editable without Jira Admin permission");
    team.template = { querySelector: () => ({ reportValidity: () => true }) };
    team.guard = async (work) => work();
    await team.saveJira();
    const saved = calls.filter((call) => call.name === "saveSetting").at(-1);
    assert.equal(JSON.parse(saved.args[0].data).connectionRevision, 17, "saving CSV options preserves the server's connection revision");
    team.jira = { ...team.jira, apiBaseUrl: "https://gateway.example.test/scope" };
    assert.equal(team.jiraSaveDisabled, true);
    assert.match(team.jiraPermissionMessage, /Atlas Jira Admin permission set/);
  } finally { globalThis.atlasJiraApex = previous; }
});

test("ticket create and pending update previews are review-first, with actionable parts disabled when finished or unresolved", async () => {
  const calls = [];
  const previous = globalThis.atlasJiraApex;
  const oldStorage = globalThis.sessionStorage;
  const stored = new Map();
  globalThis.sessionStorage = { setItem: (key, value) => stored.set(key, value), getItem: (key) => stored.get(key) || null };
  globalThis.atlasJiraApex = async (name, args) => {
    calls.push({ name, args });
    if (name === "prepareTicketWrite") return JSON.stringify({
      id: "op-create", revision: 1, requestId: "req-create", state: "reviewed", operation: "create", method: "POST",
      path: "/rest/api/3/issue", apiBaseUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", payload: { fields: { summary: "Exact" } },
    });
    if (name === "getTicket") return {
      id: "ticket-1", atlasId: "TKT-1", version: 7, summary: "Draft", description: "Text", priority: "Medium", planning: {}, pendingUpdates: [
        { id: "update-1", status: "pending", changes: { summary: "Change" }, comments: [{ text: "Comment", status: "pending" }] },
        { id: "update-2", status: "done", changes: { description: "Finished" }, comments: [{ text: "Done", status: "done" }] },
      ],
    };
    if (name === "ticketFiles") return JSON.stringify({ files: [], nextCursor: null });
    throw new Error(`Unexpected Apex call ${name}`);
  };
  try {
    const tickets = new lib.atlasTickets();
    tickets.boot = { org: { id: "org-1" }, user: { id: "user-1" } };
    tickets.settings = { jira: { siteUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", writeEnabled: true } };
    tickets.selected = { id: "ticket-2", atlasId: "TKT-2", version: 3, jiraKey: "" };
    tickets.editing = { summary: "Exact" };
    tickets.savedEditing = JSON.stringify(tickets.editing);
    await tickets.previewTicketCreation();
    const create = calls.find((call) => call.name === "prepareTicketWrite");
    assert.deepEqual(create.args, { ticketId: "ticket-2", part: "create", updateId: null, expectedVersion: 3 });
    assert.equal(tickets.jiraWrites[0].operation.state, "reviewed");
    assert.match(tickets.message, /Nothing has been sent/);
    assert.deepEqual(calls.map((call) => call.name), ["prepareTicketWrite"], "preparing never approves or sends the write");

    await tickets.openTicket({ currentTarget: { dataset: { id: "ticket-1" } } });
    const [field, comment] = tickets.selected.updates[0].parts;
    const [finishedField, finishedComment] = tickets.selected.updates[1].parts;
    assert.equal(field.actionDisabled, false);
    assert.equal(comment.actionDisabled, false);
    assert.equal(finishedField.actionDisabled, true);
    assert.equal(finishedComment.actionDisabled, true);
    assert.match(ticketsHtml, /Preview Jira ticket creation/);
    assert.match(ticketsHtml, /hasExternalJiraCredential/);
    assert.match(ticketsHtml, /Export drafts for Jira/);
  } finally {
    globalThis.atlasJiraApex = previous;
    if (oldStorage === undefined) delete globalThis.sessionStorage;
    else globalThis.sessionStorage = oldStorage;
  }
});

test("ticket reload stores only operation IDs and restores placeholders without resending", () => {
  const oldStorage = globalThis.sessionStorage;
  const stored = new Map();
  globalThis.sessionStorage = { setItem: (key, value) => stored.set(key, value), getItem: (key) => stored.get(key) || null };
  try {
    const boot = { org: { id: "org-recover" }, user: { id: "user-recover" } };
    const ticket = new lib.atlasTickets();
    ticket.boot = boot;
    ticket.jiraWrites = [{ id: "op-unknown", ticketId: "ticket-1", part: "create", updateId: null, expectedVersion: 4,
      contextLabel: "creation of TKT-1", operation: { id: "op-unknown", state: "unknown", payload: { secretLike: "not persisted" } } }];
    ticket.cacheRecovery();
    const snapshot = JSON.parse(stored.get("atlas-tickets:org-recover:user-recover"));
    assert.deepEqual(snapshot.jiraWrites, [{ id: "op-unknown", ticketId: "ticket-1", part: "create", updateId: null, expectedVersion: 4, contextLabel: "creation of TKT-1", state: "unknown" }]);
    assert.doesNotMatch(JSON.stringify(snapshot), /secretLike/);

    const restored = new lib.atlasTickets();
    restored.boot = boot;
    restored.load = async () => {};
    restored.connectedCallback();
    assert.equal(restored.jiraWrites[0].id, "op-unknown");
    assert.deepEqual(restored.jiraWrites[0].operation, { id: "op-unknown", state: "loading" });
    assert.match(restored.recoveryStatus, /no Jira request will be sent again automatically/i);
  } finally {
    if (oldStorage === undefined) delete globalThis.sessionStorage;
    else globalThis.sessionStorage = oldStorage;
  }
});

test("summary-only write reviews load details only on request and never approve an unknown outcome", async () => {
  const calls = [];
  const previous = globalThis.atlasJiraApex;
  globalThis.atlasJiraApex = async (name, args) => {
    calls.push({ name, args });
    if (name === "getWrite") return JSON.stringify({ id: args.operationId, revision: 2, requestId: "req-1", state: "reviewed", operation: "create", method: "POST",
      path: "/rest/api/3/issue", apiBaseUrl: "https://jira.example.test", namedCredential: "Jira_NC", externalCredential: "Jira_Auth", payload: { fields: { summary: "Exact" } } });
    if (name === "approveWrite") return JSON.stringify({ id: args.operationId, revision: 3, state: "queued", operation: "create", apiBaseUrl: "https://jira.example.test", path: "/rest/api/3/issue", payload: {} });
    throw new Error(`Unexpected Apex call ${name}`);
  };
  try {
    const summary = { summary: true, id: "op-1", revision: 1, requestId: "req-1", state: "reviewed", operation: "create", message: "Ready", conversationId: "c-1", ticketId: "t-1" };
    const reviews = Array.from({ length: 50 }, (_, i) => {
      const review = new lib.atlasJiraReview();
      review.isConnected = true;
      review.operation = { ...summary, id: `op-${i}` };
      return review;
    });
    assert.equal(calls.length, 0, "compact reviewed summaries must not trigger 50 full-record fetches");
    assert.equal(reviews[0].needsFullReview, true);
    assert.equal(reviews[0].needsConfirmation, false);
    assert.equal(reviews[0].canApprove, false);
    assert.match(reviews[0].statusLabel, /load the exact request before approval/i);
    reviews[0].isConnected = false;

    await reviews[0].viewSavedReview();
    assert.deepEqual(calls.map((call) => call.name), ["getWrite"]);
    assert.equal(reviews[0].hasFullReview, true);
    assert.equal(reviews[0].needsConfirmation, true);
    await reviews[0].approve();
    assert.equal(calls.filter((call) => call.name === "approveWrite").length, 0, "approval requires the explicit confirmation checkbox");
    reviews[0].handleConfirmation({ detail: { checked: true } });
    await reviews[0].approve();
    assert.equal(calls.filter((call) => call.name === "approveWrite").length, 1);

    const unknown = new lib.atlasJiraReview();
    unknown.isConnected = true;
    unknown.operation = { ...summary, id: "op-unknown", state: "unknown" };
    assert.equal(calls.length, 2, "unknown summaries are not fetched automatically");
    assert.equal(unknown.canApprove, false);
    await unknown.checkStatus();
    assert.equal(calls.filter((call) => call.name === "approveWrite").length, 1);
    assert.ok(calls.filter((call) => call.name === "getWrite").length >= 2);
    assert.match(unknown.statusLabel, /unknown|approval/i);
    assert.match(reviewHtml, /View saved Jira request/);
    assert.match(reviewHtml, /does not send or approve anything/);
  } finally { globalThis.atlasJiraApex = previous; }
});
