import { DEFAULT_REPLY_LIMIT, replyLimit } from "./protocol";
import { parseMapping } from "./jira";

export const TEST_LEVELS = [
  { label: "Salesforce default (production runs local tests)", value: "Default" },
  { label: "Only the tests the agent named", value: "RunSpecifiedTests" },
  { label: "All tests in my org", value: "RunLocalTests" },
  { label: "No tests (sandboxes and dev orgs only)", value: "NoTestRun" },
];

function json(text, fallback) {
  try {
    return text ? { ...fallback, ...JSON.parse(text) } : { ...fallback };
  } catch {
    return { ...fallback };
  }
}

/** A review recipient, not a repair developer. Never infer a Jira identity from a name or SSO value. */
export function jiraReviewManager(jira = {}, people = []) {
  const legacyId = typeof jira.reviewManagerPersonId === "string" ? jira.reviewManagerPersonId : "";
  const managers = people.filter((p) => p.isManager === true);
  const personId = managers.length === 1 ? managers[0].id : legacyId;
  const confirmation = managers.length === 1 ? managers[0].jiraIdentityType : jira.reviewManagerIdentityType;
  const identityType = ["accountId", "name"].includes(confirmation) ? confirmation : "";
  const result = { status: "unconfigured", personId, name: "", jiraId: "", identityType, ready: false,
    message: "Choose Manager on a person in Team & Jira before routing a suspected bug." };
  if (managers.length > 1 || (managers.length === 1 && legacyId && legacyId !== personId))
    return { ...result, personId: "", identityType: "", status: "ambiguous", message: "More than one Manager is configured. Resolve the conflicting roles in Team & Jira; Atlas will not choose one." };
  if (!personId) return result;
  const matches = people.filter((p) => p.id === personId);
  if (matches.length > 1) return { ...result, personId: "", status: "ambiguous", message: "The Manager identity appears more than once. Reload the people directory before routing." };
  const person = matches[0];
  if (!person) return { ...result, status: "unavailable", message: "The saved review manager is unavailable. Select an active person in Team & Jira; names are never matched automatically." };
  result.name = person.name || "";
  if (person.active !== true) return { ...result, status: "inactive", message: "The saved review manager is inactive. Select an active person in Team & Jira." };
  if (person.identityWarning) return { ...result, status: "identity_warning", message: "Resolve the review manager's identity warning in People before routing a bug." };
  if (typeof person.jiraId !== "string" || !person.jiraId.trim()) return { ...result, status: "missing_jira_id", message: "Add the review manager's exact Jira account ID or Data Center username in People. Do not guess it from their name or SSO ID." };
  if (!identityType) return { ...result, status: "unconfirmed_identity", message: "Confirm whether the review manager's saved Jira ID is a Cloud account ID or a Data Center username." };
  const expected = String(jira.apiVersion || "3") === "2" ? "name" : String(jira.apiVersion || "3") === "3" ? "accountId" : "";
  if (identityType !== expected) return { ...result, status: "identity_type_mismatch", message: "The review manager's confirmed identity type does not match the Jira API version. Review both settings; Atlas never converts usernames to account IDs." };
  return { ...result, status: "ready", jiraId: person.jiraId.trim(), ready: true,
    message: `${result.name} will receive suspected bugs for review and assignment, not as the repair developer. Nothing is sent by saving this setting.` };
}

/** Settings from bootstrap(), with defaults filled in. */
export function readSettings(boot) {
  const raw = boot?.settings || {};
  const jira = json(raw.jira, {
    projectKey: "",
    siteUrl: "",
    priorities: "Highest, High, Medium, Low, Lowest",
    defaultPriority: "Medium",
    reviewManagerPersonId: "",
    reviewManagerIdentityType: "",
    apiBaseUrl: "",
    namedCredential: "",
    externalCredential: "",
    apiVersion: "3",
    readEnabled: false,
    writeEnabled: false,
  });
  jira.reviewManagerPersonId = typeof jira.reviewManagerPersonId === "string" ? jira.reviewManagerPersonId : "";
  jira.reviewManagerIdentityType = ["accountId", "name"].includes(jira.reviewManagerIdentityType) ? jira.reviewManagerIdentityType : "";
  jira.apiBaseUrl = typeof jira.apiBaseUrl === "string" ? jira.apiBaseUrl : "";
  jira.namedCredential = typeof jira.namedCredential === "string" ? jira.namedCredential : "";
  jira.externalCredential = typeof jira.externalCredential === "string" ? jira.externalCredential : "";
  jira.apiVersion = ["2", "3"].includes(String(jira.apiVersion)) ? String(jira.apiVersion) : "3";
  jira.readEnabled = jira.readEnabled === true;
  jira.writeEnabled = jira.writeEnabled === true;
  const identity = json(raw.identity, { ssoField: "" });
  const mine = json(raw.mine, { replyLimit: DEFAULT_REPLY_LIMIT, testLevel: "Default", instructions: "" });
  mine.replyLimit = replyLimit(mine.replyLimit);
  let mapping = null,
    mappingError = "",
    mappingName = "",
    mappingText = "";
  if (raw["jira-mapping"]) {
    const stored = json(raw["jira-mapping"], { name: "", text: "" });
    mappingName = stored.name;
    mappingText = stored.text;
    try {
      mapping = parseMapping(stored.text);
    } catch (e) {
      mappingError = e.message;
    }
  }
  return { jira, identity, mine, mapping, mappingError, mappingName, mappingText };
}
