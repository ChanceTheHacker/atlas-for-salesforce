import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../salesforce/force-app/main/default/", import.meta.url);
const dir = await mkdtemp(join(tmpdir(), "atlas-manager-"));
const outfile = join(dir, "lib.mjs");
await build({ entryPoints: [new URL("lwc/atlasLib/atlasLib.js", root).pathname], bundle: true, platform: "node", format: "esm", outfile });
const lib = await import(outfile);
await rm(dir, { recursive: true });
const manager = { id: "manager-person", name: "Casey Lead", userId: "005lead", jiraId: "jira-lead", isManager: true, active: true, aliases: ["Casey"] };
const other = { id: "other-person", name: "Other Person", jiraId: "jira-other", active: true };

test("manager role resolves through ticket assignments, reporters, updates and mentions", () => {
  for (const value of ["manager", "my manager", " MY   MANAGER "])
    assert.equal(lib.findPerson([other, manager], value), manager);
  const checked = lib.checkTicketBatch({
    tickets: [{ ref: "T1", summary: "Review this", assignee: "manager", reporter: "my manager" }],
    updates: [{ target: "DEMO-12", changes: { assignee: "my manager" }, comments: [{ text: "Please review", mentionAliases: ["manager"] }] }],
  }, { people: [other, manager] });
  assert.deepEqual(checked.errors, []);
  assert.equal(checked.batch.tickets[0].assigneeId, manager.id);
  assert.equal(checked.batch.tickets[0].reporterId, manager.id);
  assert.equal(checked.batch.updates[0].changes.assigneeId, manager.id);
  assert.equal(checked.batch.updates[0].comments[0].mentions[0].userId, manager.jiraId);
  assert.equal(lib.findPerson([{ ...manager, jiraId: "", jiraIdentityType: "" }], "manager")?.id, manager.id,
    "Ordinary role resolution does not require Jira Bug readiness.");
});

test("missing, inactive, duplicate and warning-bearing manager roles fail closed", () => {
  for (const people of [[], [other], [{ ...manager, active: false }], [{ ...manager, identityWarning: "Changed SSO" }],
    [manager, { ...other, isManager: true }], [manager, { ...other, isManager: true, active: false }]]) {
    for (const value of ["manager", "my manager"]) {
      assert.equal(lib.findPerson(people, value), null);
      const result = lib.checkTicketBatch({ tickets: [{ ref: "T1", summary: "Review", assignee: value }] }, { people });
      assert.equal(result.errors.length, 1);
      assert.equal(result.batch.tickets[0].assigneeId, null);
    }
  }
});

test("role words never acquire authority from literal identities and collisions never choose a first row", () => {
  for (const role of ["manager", "my manager"]) {
    for (const identity of [{ aliases: [role] }, { name: role }, { jiraId: role }, { email: role }, { userName: role }, { id: role }]) {
      const collision = { ...other, ...identity };
      assert.equal(lib.findPerson([collision], role), null);
      assert.equal(lib.findPerson([manager, collision], role), null);
      assert.equal(lib.findPerson([collision, manager], role), null);
    }
    assert.equal(lib.findPerson([{ ...manager, aliases: [role] }], role)?.id, manager.id);
  }
  assert.equal(lib.findPerson([manager], "Casey"), manager);
});

test("CSV role resolution cannot fall through to a literal Jira ID", () => {
  const csv = (value) => lib.parseCSV(`Issue key,Summary,Assignee\nDEMO-1,Review,${value}`);
  assert.equal(lib.importRows(csv("my manager"), { people: [manager] }).rows[0].assigneeJiraId, manager.jiraId);
  for (const people of [[], [{ ...other, jiraId: "manager" }], [manager, { ...other, aliases: ["manager"] }], [{ ...manager, jiraId: "" }]])
    assert.throws(() => lib.importRows(csv("manager"), { people }), /manager is not a unique, verified Jira identity/);
  assert.equal(lib.importRows(csv("unknown-jira-id")).rows[0].unresolvedAssignee, "unknown-jira-id");
});

test("normal prompts label the manager without dropping overlapping roles or changing UAT", () => {
  const people = [{ ...manager, isMe: true }, { ...other, isMyReport: true }];
  const context = lib.peopleContext(people);
  assert.match(context, /Me: My manager: Casey Lead/);
  assert.match(context, /My direct report: Other Person/);
  assert.match(context, /never infer this role from a name or alias/);
  assert.match(context, /block|reconcile/);
  const settings = lib.readSettings({});
  const args = { conversation: { mode: "Task" }, boot: { people, org: {}, user: {} }, mine: settings.mine, jira: settings.jira };
  assert.match(lib.firstPrompt(args), /My manager: Casey Lead/);
  assert.match(lib.rulesReminder(args), /My manager: Casey Lead/);
  args.conversation = { mode: "uat", title: "Test process", request: "Plan safe tests", uat: { componentType: "Flow", apiName: "Account_Onboarding", goal: "Verify safe creation", testing: "" } };
  assert.doesNotMatch(lib.firstPrompt(args), /My manager: Casey Lead/);
  assert.doesNotMatch(lib.rulesReminder(args), /My manager: Casey Lead/);
});

test("server role consumers share the collision-checked lookup without recursive manager resolution", async () => {
  const source = async (name) => readFile(new URL(`classes/${name}.cls`, root), "utf8");
  const [identity, tickets, research, jira] = await Promise.all(["Atlas_Identity", "Atlas_Tickets", "Atlas_Research", "Atlas_Jira"].map(source));
  assert.match(identity, /managerRole \? Atlas_Jira\.reviewManager\(\) : null/);
  assert.match(identity, /keys\.contains\(key\) \|\| \(managerRole && String\.valueOf\(person\.Id\) == managerId\)/);
  assert.match(identity, /String\.isBlank\(managerId\).*'ambiguous'.*'conflict'/);
  assert.match(identity, /result\.get\('status'\) != 'resolved'/);
  assert.match(tickets, /Atlas_Identity\.isManagerRole\(String\.valueOf\(name\)\)[\s\S]*?Atlas_Identity\.managerIdentity\(String\.valueOf\(name\)\)[\s\S]*?continue;/);
  assert.match(research, /Atlas_Identity\.isManagerRole\(value\)[\s\S]*?Atlas_Identity\.managerIdentity\(value\)[\s\S]*?manager\.get\('userId'\) == null[\s\S]*?continue;/);
  const review = jira.slice(jira.indexOf("public static Map<String,Object> reviewManager()"), jira.indexOf("static String validateSettingPreservingManager"));
  assert.match(review, /Atlas_Identity\.enrich/);
  assert.doesNotMatch(review, /Atlas_Identity\.lookup|Atlas_Identity\.managerIdentity/);
});
