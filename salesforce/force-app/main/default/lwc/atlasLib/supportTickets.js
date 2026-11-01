import { checkJiraWrite } from "./jira-live";
import { checkTicketBatch } from "./tickets";
import { jiraReviewManager } from "./settings";
import { validDate } from "./dates";

const REPORT_KEYS = new Set([
  "type", "requestId", "organization", "productionFacts", "qaEvidence", "hypotheses",
  "likelyProblem", "confidence", "missingEvidence", "recommendedSolution", "productionSteps",
  "prerequisites", "permissions", "verification", "stopConditions", "rollback", "jiraEscalation",
]);
const TICKET_MESSAGE_KEYS = new Set(["type", "requestId", "tickets", "epics", "updates"]);
const TICKET_KEYS = new Set(["ref", "issueType", "summary", "description", "priority", "dueDate", "assignee"]);
const object = (value) => !!value && typeof value === "object" && !Array.isArray(value);
const ownKeysAllowed = (value, allowed) => Object.keys(value).every((key) => allowed.has(key));

function requiredText(value, label, max = 10000) {
  if (typeof value !== "string" || !value.trim()) throw Error(`${label} must be nonempty plain text.`);
  if (value.length > max) throw Error(`${label} cannot be longer than ${max.toLocaleString("en-US")} characters.`);
  return value.trim();
}

function textList(value, label, { min = 0, max = 100, itemMax = 10000 } = {}) {
  if (!Array.isArray(value) || value.length > max) throw Error(`${label} must be a list of at most ${max} text items.`);
  if (value.length < min) throw Error(`${label} needs at least ${min} item(s).`);
  return value.map((item, index) => requiredText(item, `${label} item ${index + 1}`, itemMax));
}

/** Strictly checks the final report before Atlas displays or acts on it. */
export function checkSupportTicketReport(message, conversationId) {
  if (!object(message) || !ownKeysAllowed(message, REPORT_KEYS))
    throw Error("A Support Tickets report contains unsupported fields. Nothing was prepared.");
  if (message.type !== "atlas-support-ticket-report" || message.requestId !== conversationId)
    throw Error("A Support Tickets report must include this conversation's exact requestId.");

  const report = {
    type: message.type,
    requestId: message.requestId,
    organization: requiredText(message.organization, "organization", 1000),
    productionFacts: textList(message.productionFacts, "productionFacts"),
    qaEvidence: textList(message.qaEvidence, "qaEvidence"),
    hypotheses: textList(message.hypotheses, "hypotheses"),
    likelyProblem: requiredText(message.likelyProblem, "likelyProblem"),
    confidence: requiredText(message.confidence, "confidence", 20),
    missingEvidence: textList(message.missingEvidence, "missingEvidence"),
    recommendedSolution: requiredText(message.recommendedSolution, "recommendedSolution"),
    productionSteps: textList(message.productionSteps, "productionSteps", { min: 1, itemMax: 5000 }),
    prerequisites: textList(message.prerequisites, "prerequisites"),
    permissions: textList(message.permissions, "permissions"),
    verification: textList(message.verification, "verification"),
    stopConditions: textList(message.stopConditions, "stopConditions", { min: 1 }),
    rollback: textList(message.rollback, "rollback"),
    jiraEscalation: null,
  };
  if (report.confidence !== "Low" && report.confidence !== "Moderate" && report.confidence !== "High")
    throw Error('confidence must be "Low", "Moderate" or "High".');
  if (!report.productionFacts.length && !report.qaEvidence.length)
    throw Error("Include at least one administrator-reported production fact or one observed Salesforce fact.");

  if (message.jiraEscalation !== null) {
    if (!object(message.jiraEscalation) || !ownKeysAllowed(message.jiraEscalation, new Set(["summary", "description"])))
      throw Error("jiraEscalation must be null or a Bug proposal with only summary and description.");
    report.jiraEscalation = {
      summary: requiredText(message.jiraEscalation.summary, "jiraEscalation.summary", 255),
      description: requiredText(message.jiraEscalation.description, "jiraEscalation.description", 131072),
    };
  }
  return report;
}

function section(title, values) {
  return `${title}\n${values.length ? values.map((value) => `- ${value}`).join("\n") : "None identified."}`;
}

/** Plain text only: bindings escape it, and the report stays readable on small screens. */
export function formatSupportTicketReport(report, connectedOrg = {}) {
  const orgName = connectedOrg.name || "Name not available";
  const orgId = connectedOrg.id || "ID not available";
  const orgType = connectedOrg.isSandbox === true ? "sandbox org" : "non-sandbox org";
  const edition = connectedOrg.edition || "edition not available";
  const namespace = connectedOrg.namespace || "none";
  const lines = [
    "SUPPORT TICKETS FINDINGS",
    `Connected Salesforce research org: ${orgName} (${orgId}); ${orgType}; ${edition}; namespace ${namespace}. This is the org Atlas queried, not proof of production behavior. A non-sandbox org is not automatically the production org.`,
    `Administrator's description of the production org: ${report.organization}`,
    section("Facts reported about production by the administrator", report.productionFacts),
    section("Evidence observed in the connected Salesforce org", report.qaEvidence),
    section("Hypotheses and differences that have not been verified", report.hypotheses),
    `Likely problem\n${report.likelyProblem}\nConfidence: ${report.confidence}`,
    section("Evidence still needed", report.missingEvidence),
    `Recommended solution\n${report.recommendedSolution}`,
    `Beginner-friendly production steps\n${report.productionSteps.map((step, i) => `${i + 1}. ${step}`).join("\n")}`,
    section("Prerequisites", report.prerequisites),
    section("Permissions needed", report.permissions),
    section("How to verify the result", report.verification),
    section("Stop and escalate if", report.stopConditions),
    section("Rollback", report.rollback),
    report.jiraEscalation
      ? `Jira Bug for manager review\n${report.jiraEscalation.summary}\n${report.jiraEscalation.description}`
      : "Jira Bug for manager review\nNo code defect was identified for Jira escalation.",
  ];
  return lines.join("\n\n");
}

/** Accepts only one Bug draft and reduces it to the server's small, safe shape. */
export function checkSupportTicketBugDraft(message, conversationId, { people = [], projectKey = "", jira = {} } = {}) {
  const errors = [];
  if (!object(message) || !ownKeysAllowed(message, TICKET_MESSAGE_KEYS))
    throw Error("A Support Tickets local draft cannot contain a project key or unsupported fields.");
  if (message.type !== "atlas-tickets" || message.requestId !== conversationId)
    throw Error("A Support Tickets Bug draft must include this conversation's exact requestId.");
  if (Array.isArray(message.epics) && message.epics.length) errors.push("Support Tickets cannot create epics.");
  if (Array.isArray(message.updates) && message.updates.length) errors.push("Support Tickets cannot update existing tickets.");
  if ((message.epics !== undefined && !Array.isArray(message.epics)) || (message.updates !== undefined && !Array.isArray(message.updates)))
    errors.push('"epics" and "updates" must be omitted or empty lists.');
  if (!Array.isArray(message.tickets) || message.tickets.length !== 1)
    errors.push("Support Tickets can prepare exactly one Bug at a time.");
  const raw = message.tickets?.[0];
  if (!object(raw)) errors.push("The Bug must be a JSON object.");
  else {
    if (!ownKeysAllowed(raw, TICKET_KEYS)) errors.push("The Bug contains unsupported fields; no project, reporter, epic, dependency or custom field can be supplied.");
    if (raw.issueType !== "Bug") errors.push('The only allowed issueType is "Bug".');
    if (typeof raw.ref !== "string" || !raw.ref.trim() || raw.ref.length > 80) errors.push('The Bug needs a unique nonempty "ref" of at most 80 characters.');
    if (typeof raw.summary !== "string" || !raw.summary.trim() || raw.summary.length > 255) errors.push('The Bug needs a summary of 1–255 characters.');
    if (typeof raw.description !== "string" || !raw.description.trim() || raw.description.length > 131072) errors.push("The Bug needs a nonempty description of at most 131,072 characters.");
    if (raw.priority !== undefined && typeof raw.priority !== "string") errors.push("priority must be text when supplied.");
    if (raw.dueDate !== undefined && (typeof raw.dueDate !== "string" || !validDate(raw.dueDate))) errors.push("dueDate must be a real date in YYYY-MM-DD format and must have been reported by the administrator.");
    const manager = jiraReviewManager(jira, people);
    const expectedAssignee = manager.ready ? manager.jiraId : null;
    if (!Object.hasOwn(raw, "assignee") || raw.assignee !== expectedAssignee)
      errors.push(manager.ready
        ? `Set assignee to the configured review manager's exact Jira ID, ${manager.jiraId}.`
        : `Set assignee to null because no confirmed review manager is available. ${manager.message}`);
  }
  if (errors.length) return { errors, batch: null, manager: jiraReviewManager(jira, people) };

  const manager = jiraReviewManager(jira, people);
  const ticket = raw;
  const checked = checkTicketBatch({
    type: "atlas-tickets",
    tickets: [{
      ref: ticket.ref.trim(), issueType: "Bug", summary: ticket.summary.trim(), description: ticket.description.trim(),
      ...(ticket.priority !== undefined ? { priority: ticket.priority } : {}),
      ...(ticket.dueDate !== undefined ? { dueDate: ticket.dueDate, dueDateSource: "input" } : {}),
      assignee: manager.ready ? manager.jiraId : null,
    }],
  }, { people, projectKey });
  if (checked.errors.length) return { errors: checked.errors, batch: null, manager };
  const normalized = checked.batch.tickets[0];
  return {
    errors: [],
    manager,
    batch: {
      projectKey,
      epics: [],
      tickets: [{
        ref: normalized.ref,
        issueType: "Bug",
        summary: normalized.summary,
        description: normalized.description,
        priority: normalized.priority,
        dueDate: ticket.dueDate ?? null,
        assigneeId: normalized.assigneeId,
      }],
      updates: [],
    },
  };
}

/** Further narrows the shared Jira validator to a manager-assigned Bug creation. */
export function checkSupportTicketJiraWrite(message, conversationId, { people = [], jira = {} } = {}) {
  if (!jira.externalCredential?.trim() || jira.writeEnabled !== true)
    throw Error("Live Jira writes are not available. Use the local Bug draft for manual CSV export instead.");
  const manager = jiraReviewManager(jira, people);
  if (!manager.ready) throw Error(`A live Jira Bug needs a confirmed review manager. ${manager.message}`);
  if (!jira.projectKey || !/^[A-Z][A-Z0-9_]*$/.test(jira.projectKey))
    throw Error("Set a valid Jira project key in Team & Jira, or use the local Bug draft.");

  const request = checkJiraWrite(message, conversationId);
  if (request.operation !== "create") throw Error("Support Tickets can only propose a new Jira Bug for review.");
  const fields = message.fields;
  const allowedFields = new Set(["project", "issuetype", "summary", "description", "assignee", "labels", "priority", "duedate"]);
  if (!object(fields) || !ownKeysAllowed(fields, allowedFields)) throw Error("The Bug can contain only project, issue type, summary, description, manager assignment, review label, and optional explicit priority and due date.");
  if (!object(fields.project) || !ownKeysAllowed(fields.project, new Set(["key"])) || fields.project.key !== jira.projectKey)
    throw Error("The Jira Bug must use the configured project key exactly.");
  if (!object(fields.issuetype) || !ownKeysAllowed(fields.issuetype, new Set(["name"])) || fields.issuetype.name !== "Bug")
    throw Error('The Jira issue type must be exactly "Bug".');
  requiredText(fields.summary, "Bug summary", 255);
  requiredText(fields.description, "Bug description", 131072);
  if (fields.priority !== undefined) {
    if (!object(fields.priority) || !ownKeysAllowed(fields.priority, new Set(["name"]))) throw Error("priority must contain only its exact Jira name.");
    requiredText(fields.priority.name, "Bug priority name", 128);
  }
  if (fields.duedate !== undefined && (typeof fields.duedate !== "string" || !validDate(fields.duedate)))
    throw Error("duedate must be a real YYYY-MM-DD date when supplied.");
  const assigneeKey = manager.identityType === "accountId" ? "accountId" : "name";
  if (!object(fields.assignee) || !ownKeysAllowed(fields.assignee, new Set([assigneeKey])) || fields.assignee[assigneeKey] !== manager.jiraId)
    throw Error("Assign the Bug to the configured review manager using their exact, confirmed Jira identity.");
  if (!Array.isArray(fields.labels) || fields.labels.length !== 1 || fields.labels[0] !== "atlas-manager-review")
    throw Error('Include exactly the "atlas-manager-review" Jira label.');
  return request;
}

const UNVERIFIABLE_CREDENTIAL_ERROR = "Cannot verify the selected Jira Named Credential endpoint and linked External Credential. Ask your Salesforce administrator to check this connection and your access.";

/** Only this deterministic server-side preflight rejection is safe for a local-draft fallback. */
export function isSupportTicketCredentialVerificationFailure(error) {
  const message = typeof error === "string" ? error
    : error?.body?.message || error?.body?.pageErrors?.[0]?.message || error?.message || "";
  return message === UNVERIFIABLE_CREDENTIAL_ERROR;
}

function stableHash(text) {
  let hash = 2166136261;
  for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 16777619) >>> 0;
  return hash.toString(16);
}

function connectionHash(text) {
  let first = 2166136261;
  let second = 0x9e3779b9;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    first = Math.imul(first ^ code, 16777619) >>> 0;
    second = Math.imul(second ^ (code + i), 2246822519) >>> 0;
  }
  return `${first.toString(16).padStart(8, "0")}${second.toString(16).padStart(8, "0")}`;
}

/** Deterministic retry identity changes whenever the exact auto-routed Bug destination changes. */
export function supportTicketBugOperationId(conversationId, summary, description, routing = {}) {
  const text = JSON.stringify([
    conversationId,
    routing.projectKey || "",
    summary,
    description,
    routing.identityType || "",
    routing.jiraId || "",
  ]);
  return `atlas-ticket-bug-${stableHash(text)}`;
}

function supportTicketJiraConnectionIdentity(jira = {}) {
  const siteUrl = typeof jira.siteUrl === "string" ? jira.siteUrl : "";
  const apiBaseUrl = typeof jira.apiBaseUrl === "string" && jira.apiBaseUrl ? jira.apiBaseUrl : siteUrl;
  return JSON.stringify([
    siteUrl,
    apiBaseUrl,
    typeof jira.namedCredential === "string" ? jira.namedCredential : "",
    typeof jira.externalCredential === "string" ? jira.externalCredential : "",
    String(jira.apiVersion || "3"),
    jira.readEnabled === true,
    jira.writeEnabled === true,
    jira.connectionRevision ?? null,
  ]);
}

/**
 * Reuses any saved non-invalidated review. A new generation is allowed only
 * after the server's latest receipt proves the old review was invalidated and
 * nothing was sent. Its ID includes the complete current Jira connection.
 */
export function supportTicketBugReviewOperationId(baseId, jira = {}, writes = []) {
  const prefix = `${baseId}-retry-`;
  const matching = writes.filter((row) => row?.requestId === baseId || row?.requestId?.startsWith(prefix));
  const existing = matching.find((row) => row.state !== "invalidated");
  if (existing) return existing.requestId;
  if (!matching.length) return baseId;

  // listWrites is newest-first. Do not trust missing or stale browser receipts.
  const latest = matching[0];
  if (latest.state !== "invalidated" || typeof latest.message !== "string" || !latest.message.includes("Nothing was sent."))
    return null;

  const connectionHashValue = connectionHash(supportTicketJiraConnectionIdentity(jira));
  if (latest.requestId === baseId) {
    if (!latest.message.startsWith("Jira configuration changed after review.")) return null;
  } else {
    const previousHash = latest.requestId.match(/-retry-\d+-([0-9a-f]{16})$/)?.[1];
    if (!previousHash || previousHash === connectionHashValue) return null;
  }

  const savedIds = new Set(matching.map((row) => row.requestId));
  for (let generation = 1; ; generation++) {
    const candidate = `${baseId}-retry-${generation}-${connectionHashValue}`;
    if (!savedIds.has(candidate)) return candidate;
  }
}

export function validateSupportTicketMessageType(message) {
  const allowed = new Set(["atlas-request", "atlas-questions", "atlas-support-ticket-report", "atlas-tickets", "atlas-jira-write"]);
  if (!allowed.has(message?.type))
    throw Error(`Support Tickets cannot process ${message?.type || "this message"}. Only read-only research, clarifying questions, a final findings report and a manager-reviewed Bug proposal are allowed.`);
}
