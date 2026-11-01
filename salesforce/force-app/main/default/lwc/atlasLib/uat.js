// UAT is research and a human-executed test document, never an execution channel.
const object = (v) => !!v && typeof v === "object" && !Array.isArray(v);
export const UAT_COMPONENT_TYPES = ["Flow", "Apex", "LWC", "Other"];
export const UAT_READ_OPS = ["soql", "tooling", "sosl", "describe", "metadata-types", "metadata-list", "retrieve", "rest", "activity"];
export const UAT_COVERAGE = ["happy path", "edge cases", "boundary", "bulk", "roles and security", "errors", "regression", "async", "integrations"];
export const UAT_BOUNDARY = "UAT is read-only research. Never execute tests, code, flows, deployments, record changes, assignments, Jira writes or local ticket changes here. The user executes the plan in a confirmed safe test environment. Only atlas-request, atlas-questions and atlas-uat-plan are accepted. Report failed tests with their IDs, expected and actual results, environment/version and evidence; investigate read-only and provide a copyable Source-mode repair prompt, not fixes here.";

function shape(value, keys, label) {
  if (!object(value) || Object.keys(value).some((key) => !keys.includes(key))) throw Error(`${label} contains invalid or unsupported fields.`);
}
function text(value, label, max = 4000) {
  if (typeof value !== "string" || !value.trim() || value.length > max || /[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]/.test(value)) throw Error(`${label} needs 1–${max.toLocaleString("en-US")} characters of plain text without XML control characters.`);
  return value.trim();
}
function list(value, label, min = 0, max = 50, itemMax = 4000) {
  if (!Array.isArray(value) || value.length < min || value.length > max) throw Error(`${label} needs ${min}–${max} items.`);
  return value.map((v, i) => text(v, `${label} ${i + 1}`, itemMax));
}
function rows(value, label, min, max, normalize) {
  if (!Array.isArray(value) || value.length < min || value.length > max) throw Error(`${label} needs ${min}–${max} entries.`);
  return value.map(normalize);
}

/** Incomplete drafts are allowed, but malformed recovery fields are not. */
export function validUatDraft(value) {
  return value === undefined || object(value) && Object.keys(value).every((k) => ["componentType", "apiName", "goal", "testing"].includes(k))
    && Object.values(value).every((v) => typeof v === "string");
}
export function checkUatIntake(conversation) {
  const uat = conversation.uat;
  shape(uat, ["componentType", "apiName", "goal", "testing"], "UAT intake");
  if (!UAT_COMPONENT_TYPES.includes(uat.componentType)) throw Error("Choose Flow, Apex, LWC or Other for UAT.");
  const normalized = {componentType: uat.componentType, apiName: text(uat.apiName, "API name", 255), goal: text(uat.goal, "Brief goal", 2000), testing: ""};
  if (uat.componentType === "Other" || uat.testing) normalized.testing = text(uat.testing, "What you are testing", 2000);
  text(conversation.request, "UAT prompt", 30000);
  return normalized;
}
export function uatIntakeText(conversation) {
  const uat = checkUatIntake(conversation);
  return `Component type: ${uat.componentType}\nAPI name: ${uat.apiName}\nBrief goal: ${uat.goal}${uat.testing ? `\nWhat I am testing: ${uat.testing}` : ""}\nMy prompt: ${conversation.request.trim()}`;
}

export function validateUatMessageType(message) {
  if (!["atlas-request", "atlas-questions", "atlas-uat-plan"].includes(message?.type)) throw Error(`UAT cannot process ${message?.type || "this message"}. Only read-only research, clarifying questions and a validated UAT Word plan are allowed.`);
  if (message.type === "atlas-request") {
    if (!Array.isArray(message.requests) || !message.requests.length || message.requests.length > 25) throw Error("UAT research needs 1–25 read-only requests.");
    for (const request of message.requests) {
      if (!object(request) || !UAT_READ_OPS.includes(request.op)) throw Error(`UAT does not allow research operation ${request?.op || "(missing)"}. Use read-only Salesforce research, not Jira, tickets, aliases or execution.`);
      if ((request.method !== undefined && request.method !== "GET") || request.body !== undefined || request.action !== undefined) throw Error("UAT research cannot contain write methods, bodies or actions.");
      if (request.op === "rest") {
        const raw = text(request.path, "Read-only REST path", 12000);
        const [route, query = "", ...extra] = raw.split("?");
        const path = route.replace(/^\/services\/data\/v\d+\.\d+/, "").replace(/\/$/, "");
        const queryRoute = /^\/(?:query|queryAll|search|tooling\/query)$/.test(path);
        const recordUI = /^\/ui-api\/record-ui\/[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?(?:,[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?)*$/.test(path);
        const readRoute = /^\/limits$|^\/(?:tooling\/)?sobjects(?:\/[A-Za-z][A-Za-z0-9_]*\/describe)?$|^\/(?:query|queryAll|tooling\/query)\/[A-Za-z0-9_-]+$/.test(path);
        if (extra.length || /[%#\\\\]|\.\./.test(route) || (!queryRoute && !recordUI && !readRoute)) throw Error("UAT REST requests permit only approved read-only query, describe, limits and record-ui routes; execution and mutation endpoints are forbidden.");
        const allowed = queryRoute ? ["q"] : recordUI ? ["layoutTypes", "modes", "optionalFields", "childRelationships", "formFactor"] : [];
        if ([...new URLSearchParams(query).keys()].some((key) => !allowed.includes(key))) throw Error("UAT REST requests contain unsupported query parameters; method overrides are forbidden.");
      }
    }
  }
}

/** A bounded, explicit plan. Unknown fields cannot smuggle arbitrary Files artifacts. */
export function checkUatPlan(message, conversationId) {
  shape(message, ["type", "requestId", "title", "summary", "environment", "scope", "evidence", "dependencies", "limitations", "prerequisites", "testData", "cleanup", "coverage", "tests", "findings"], "UAT plan");
  if (message.type !== "atlas-uat-plan" || typeof conversationId !== "string" || !conversationId || message.requestId !== conversationId) throw Error("A UAT plan needs this conversation's exact requestId.");
  if (JSON.stringify(message).length > 500000) throw Error("The UAT plan exceeds 500,000 characters. Narrow the scope or send separate complete plans.");
  const plan = {type: message.type, requestId: conversationId, title: text(message.title, "Plan title", 120), summary: text(message.summary, "Plan summary"), environment: text(message.environment, "Safe test environment"), scope: text(message.scope, "Process scope")};
  plan.evidence = rows(message.evidence, "Evidence", 1, 60, (e) => {
    shape(e, ["source", "observation"], "Evidence");
    return {source: text(e.source, "Evidence source", 1000), observation: text(e.observation, "Evidence observation")};
  });
  plan.dependencies = rows(message.dependencies, "Dependencies", 0, 60, (d) => {
    shape(d, ["name", "version", "evidence", "status"], "Dependency");
    if (!["inspected", "inaccessible", "unverified"].includes(d.status)) throw Error("Dependency status must be inspected, inaccessible or unverified.");
    return {name: text(d.name, "Dependency name", 255), version: text(d.version, "Dependency version or explicit unknown", 255), evidence: text(d.evidence, "Dependency evidence or access limitation"), status: d.status};
  });
  for (const key of ["limitations", "prerequisites", "testData", "cleanup"]) plan[key] = list(message[key], key, key === "limitations" ? 0 : 1);
  const ids = new Set();
  let stepCount = 0;
  plan.tests = rows(message.tests, "Tests", 1, 40, (t) => {
    shape(t, ["id", "title", "role", "preconditions", "data", "steps", "expectedResult", "cleanup"], "Test");
    const id = text(t.id, "Test ID", 40);
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(id) || ids.has(id)) throw Error("Each test needs a unique ID using letters, numbers, underscores or hyphens.");
    ids.add(id);
    const steps = rows(t.steps, `${id} steps`, 1, 30, (s) => {
      shape(s, ["action", "expected"], `${id} step`);
      return {action: text(s.action, `${id} step action`, 1500), expected: text(s.expected, `${id} step expected result`, 1500)};
    });
    stepCount += steps.length;
    return {id, title: text(t.title, `${id} title`, 255), role: text(t.role, `${id} role`, 1000), preconditions: list(t.preconditions, `${id} preconditions`, 1, 20), data: list(t.data, `${id} data`, 1, 20), steps, expectedResult: text(t.expectedResult, `${id} expected result`), cleanup: list(t.cleanup, `${id} cleanup`, 1, 20)};
  });
  if (stepCount > 200) throw Error("A UAT plan supports at most 200 total steps. Split it into scoped complete plans.");
  const references = (value, label, min = 0) => {
    const refs = list(value, label, min, 40, 40);
    if (refs.some((id) => !ids.has(id)) || new Set(refs).size !== refs.length) throw Error(`${label} must reference unique test IDs present in this plan.`);
    return refs;
  };
  plan.coverage = rows(message.coverage, "Coverage", UAT_COVERAGE.length, UAT_COVERAGE.length, (c) => {
    shape(c, ["area", "applicable", "rationale", "testIds"], "Coverage");
    if (!UAT_COVERAGE.includes(c.area) || typeof c.applicable !== "boolean") throw Error("Each coverage area needs its defined name and an applicable boolean.");
    return {area: c.area, applicable: c.applicable, rationale: text(c.rationale, "Coverage rationale"), testIds: references(c.testIds, "Coverage test IDs", c.applicable ? 1 : 0)};
  });
  if (new Set(plan.coverage.map((c) => c.area)).size !== UAT_COVERAGE.length) throw Error("Cover every required test area once; explain anything not applicable.");
  plan.findings = rows(message.findings, "Suspected findings", 0, 20, (f, i) => {
    shape(f, ["id", "summary", "evidence", "testIds", "sourcePrompt"], "Finding");
    return {id: text(f.id, `Finding ${i + 1} ID`, 40), summary: text(f.summary, "Suspected finding summary"), evidence: list(f.evidence, "Finding evidence", 1, 20), testIds: references(f.testIds, "Finding test IDs"), sourcePrompt: text(f.sourcePrompt, "Source-mode repair prompt", 12000)};
  });
  if (new Set(plan.findings.map((f) => f.id)).size !== plan.findings.length) throw Error("Finding IDs must be unique.");
  return plan;
}

function repairPrompt(plan, finding) {
  return `Open a separate Source-mode conversation. Investigate before changing anything. This is a suspected defect, not a confirmed diagnosis.\nUAT conversation: ${plan.requestId}\nFinding ${finding.id}: ${finding.summary}\nRelated tests: ${finding.testIds.join(", ") || "Not yet isolated"}\nEvidence:\n${finding.evidence.join("\n")}\n\n${finding.sourcePrompt}\n\nRe-read the current versions and verify the cause. Explain uncertainties and regression risks. Follow Source mode's backup, diff and human approval process before any repair. No repair is authorized by this UAT report.`;
}
export function uatRepairPrompts(plan) {
  return plan.findings.map((f) => ({id: f.id, title: `Suspected finding ${f.id}: ${f.summary}`, text: repairPrompt(plan, f)}));
}

/** Deterministic Word definition; interactive controls are built by the shared Files library. */
export function uatPlanToArtifact(message, conversationId = message?.requestId) {
  const plan = checkUatPlan(message, conversationId);
  const blocks = [];
  const heading = (value, level = 1) => blocks.push({type: "heading", level, text: value});
  const paragraph = (value) => {
    // Generated context can be longer than an individual schema field. Preserve it
    // without exceeding the shared Word paragraph limit or splitting a surrogate.
    for (let start = 0; start < value.length;) {
      let end = Math.min(start + 18000, value.length);
      if (end < value.length && /[\uD800-\uDBFF]/.test(value[end - 1])) end--;
      const part = value.slice(start, end);
      if (part.trim()) blocks.push({type: "paragraph", text: part});
      start = end;
    }
  };
  const bullets = (values) => {
    if (values.some((value) => value.length > 4000)) values.forEach(paragraph);
    else if (values.length) blocks.push({type: "bullets", items: values});
  };
  const checks = (values) => blocks.push({type: "checklist", items: values.map((value) => ({text: value, checked: false}))});
  heading(plan.title);
  paragraph(plan.summary);
  paragraph(`UAT conversation: ${plan.requestId}. No tests have been executed by Atlas. Check the boxes in Microsoft Word as you execute each test. Mark exactly one outcome per step and test. Blank outcomes mean not run, not passed. Record actual results and evidence; blocked is not a pass.`);
  paragraph(UAT_BOUNDARY);
  heading("Scope and safe environment"); paragraph(plan.scope); paragraph(plan.environment);
  checks(["I have confirmed the correct safe test environment, component versions, permissions and isolated test data before executing anything."]);
  heading("Research evidence"); bullets(plan.evidence.map((e) => `${e.source}: ${e.observation}`));
  heading("Reachable dependencies and versions"); bullets(plan.dependencies.map((d) => `${d.name} — ${d.status}; version: ${d.version}. ${d.evidence}`));
  heading("Limitations and unresolved questions"); bullets(plan.limitations.length ? plan.limitations : ["No further limitation was reported by the agent. This is not proof that every dependency is accessible or fully understood."]);
  for (const [key, label] of [["prerequisites", "Prerequisites and permissions"], ["testData", "Test data"], ["cleanup", "Overall cleanup and restoration"]]) { heading(label); bullets(plan[key]); }
  heading("Coverage review"); bullets(plan.coverage.map((c) => `${c.area}: ${c.applicable ? "Covered" : "Not applicable"}. ${c.rationale} Tests: ${c.testIds.join(", ") || "None"}.`));
  heading("Execution record"); paragraph("Tester: ____________________ Date/time: ____________________ Org/environment: ____________________ Component/version: ____________________");
  for (const t of plan.tests) {
    heading(`${t.id}: ${t.title}`);
    paragraph(`Role/security context: ${t.role}`);
    bullets(t.preconditions.map((v) => `Prerequisite: ${v}`).concat(t.data.map((v) => `Test data: ${v}`)));
    for (const [index, step] of t.steps.entries()) {
      const id = `${t.id}.${index + 1}`;
      paragraph(`${id}. ${step.action}\nExpected: ${step.expected}`);
      checks([`${id} Pass`, `${id} Fail`, `${id} Blocked`]);
      paragraph(`${id} Actual result / evidence / error / record reference: ____________________________________________________________`);
    }
    paragraph(`Overall expected result: ${t.expectedResult}`);
    checks([`${t.id} Pass`, `${t.id} Fail`, `${t.id} Blocked`]);
    paragraph(`${t.id} Actual result / evidence / finding ID / blocker: ____________________________________________________________`);
    bullets(t.cleanup.map((v) => `Cleanup: ${v}`));
    checks([`${t.id} Cleanup completed or documented as not applicable`]);
  }
  heading("Suspected findings and Source-mode repair prompts");
  if (!plan.findings.length) paragraph("No suspected defect was reported. This does not mean the unexecuted tests passed.");
  for (const f of uatRepairPrompts(plan)) { heading(`Suspected finding ${f.id}`, 2); paragraph(f.text); }
  heading("Report a failed or blocked test in the same UAT conversation");
  paragraph("Use Report test results in Atlas. Include the test and step IDs, expected versus actual results, environment/version, role, timestamp, record references and sanitized screenshots/log excerpts. The agent can ask questions and research further; it must not fix or run anything here. Use the separate Source-mode prompt for a proposed repair.");
  if (blocks.length > 500) throw Error("This UAT plan needs more than 500 Word blocks. Reduce tests or steps and split it into smaller complete plans.");
  return {kind: "docx", name: "UAT-plan.docx", title: plan.title, blocks};
}

export function uatFailureReport({testIds, expected, actual, evidence}, conversationId) {
  const report = {type: "atlas-uat-results", requestId: conversationId, testIds: text(testIds, "Test and step IDs", 1000), expected: text(expected, "Expected results", 4000), actual: text(actual, "Actual results or blocker", 4000), evidence: text(evidence, "Evidence and environment/version", 8000)};
  return JSON.stringify(report, null, 2) + "\n\nThese results are user-reported, not independently verified. Investigate using read-only research; ask targeted questions about missing evidence. Return a plain-text Source-mode repair prompt for any suspected defect, or a revised atlas-uat-plan if the plan needs updating. Do not require the whole initial plan again when its test IDs and history are available.\n" + UAT_BOUNDARY;
}
