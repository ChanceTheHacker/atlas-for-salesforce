import { findPerson } from "./tickets";

/** Keep human answers only when both the question ID and its wording still match. */
export function intakeQuestions(message, previous = []) {
  if (!Array.isArray(message.questions) || !message.questions.length || message.questions.length > 10)
    throw Error("Ask 1–10 essential questions after researching Salesforce and saved context.");
  const seen = new Set();
  return message.questions.map((q) => {
    if (!q || Object.keys(q).some((k) => !["id", "question"].includes(k)))
      throw Error("Agents may supply questions, never answers or extra fields.");
    if (!/^[A-Za-z][A-Za-z0-9_-]{0,39}$/.test(q.id) || typeof q.question !== "string" || !q.question.trim() || q.question.length > 2000)
      throw Error("Each question needs a short ID and a question of at most 2,000 characters.");
    if (seen.has(q.id)) throw Error("Question IDs must be unique.");
    seen.add(q.id);
    return { id: q.id, question: q.question, answer: previous.find((p) => p.id === q.id && p.question === q.question)?.answer || "" };
  });
}

export function intakeAliases(message, people = []) {
  if (!Array.isArray(message.aliases) || !message.aliases.length || message.aliases.length > 20)
    throw Error("Request 1–20 aliases at a time.");
  const seen = new Set();
  return message.aliases.map((a) => {
    if (!a || Object.keys(a).some((k) => !["alias", "reason"].includes(k)))
      throw Error("Agents cannot supply or overwrite user IDs. Request an alias and reason only.");
    if (typeof a.alias !== "string" || !a.alias.trim() || a.alias.length > 120 || /[,;\x00-\x1f]/.test(a.alias) || typeof a.reason !== "string" || !a.reason.trim() || a.reason.length > 1000)
      throw Error("Each identity needs one short alias and a reason.");
    const key = a.alias.trim().toLowerCase();
    if (seen.has(key)) throw Error("Request each alias only once.");
    seen.add(key);
    return { alias: a.alias.trim(), reason: a.reason, personId: findPerson(people, a.alias)?.id || "" };
  });
}

export const INTAKE_PROTOCOL = `CLARIFICATIONS AND IDENTITIES
After researching Salesforce and saved context, request unresolved business choices with {"type":"atlas-questions","questions":[{"id":"Q1","question":"Which behavior should apply?"}]}. Atlas presents persistent answer fields and returns atlas-answers. Never supply answers yourself.
For an unknown person, first request {"type":"atlas-request","requests":[{"id":"who","op":"users","term":"Sam"}]} to search Salesforce and the configured SSO field. Do not guess from suggestions, ambiguous or incomplete results. To confirm a new nickname, send {"type":"atlas-users","aliases":[{"alias":"Sam","reason":"Confirm the assignee"}]}. The human selects a confirmed person in Atlas; wait for atlas-users-result. Never invent or change Jira account IDs. Salesforce User IDs are separate. Saved PEOPLE names/aliases/Jira IDs can be used directly in assignee. For Jira comment mentions ask the human to select the confirmed person in Jira's @ picker; text alone is not a notification.
SAVED CONTEXT
Use {"type":"atlas-context","libraryId":"record ID","search":"optional text","offset":0,"maxChars":20000} to read the saved notebook or document library. Omit libraryId to list available libraries. Request only relevant sections, follow returned nextOffset and pin versionId from the first response on every subsequent page. Documents accept section/start/end (1-based, up to 200 lines) or search; search results are excerpts and section reads retrieve complete lines. Notebook views: view:"source" with path/start/end reads a saved source range; view:"graph" returns the snapshot dependency graph; view:"pack" reads the complete selected source context pack. Source notebooks preserve business briefs, notes, feature groups, cached files and context packs; cached source is evidence, not the deployed baseline. Always research live metadata before a change.
JIRA REFRESH
When a Jira fact is stale, request a scoped Jira search with {"type":"atlas-jira-refresh","keys":["ABC-1"],"reason":"Need current status"}. With live Jira Read enabled, Atlas reads those issues directly. With no credential, Atlas generates copyable JQL and waits for the human to import the fresh CSV. A configured but disabled or failing connection is not permission to pretend the mirror is current. Do not infer that Salesforce activity changed Jira status.`;
