// Checks an agent's atlas-tickets message and turns names, aliases and Jira IDs
// into Atlas people before anything is saved. Problems go back to the agent.
import { suggestedDueDate, validDate } from "./dates";

const TEXT_LIMITS = { summary: 255, description: 131072, dueDateNote: 1000, dependsOn: 255, epicName: 255 };

/** Unique exact identity across every namespace; collisions never pick the first row. */
export function findPerson(people, value) {
  const key = (text) => String(text ?? "").trim().replace(/\s+/g, " ").toLowerCase();
  const v = key(value);
  if (!v) return null;
  const managerRole = v === "manager" || v === "my manager";
  const managers = (people || []).filter((p) => p.isManager === true);
  // Role words are reserved: a literal alias alone never creates a manager.
  if (managerRole && (managers.length !== 1 || managers[0].active === false)) return null;
  const matches = (people || []).filter((p) => p.active !== false &&
    ((managerRole && p === managers[0]) ||
      [p.id, p.userId, p.jiraId, p.name, p.userName, p.email, p.loginName, p.username, ...(p.aliases || [])].some((name) => key(name) === v)));
  return matches.length === 1 && !matches[0].identityWarning ? matches[0] : null;
}

export function checkTicketBatch(message, { people = [], projectKey = "" } = {}) {
  const errors = [];
  const me = people.find((p) => p.isMe) || null;
  const refs = new Set();
  const epicRefs = new Set();
  const epics = Array.isArray(message.epics) ? message.epics : [];
  const tickets = Array.isArray(message.tickets) ? message.tickets : [];
  const updates = Array.isArray(message.updates) ? message.updates : [];
  if (!epics.length && !tickets.length && !updates.length)
    errors.push('Send at least one item in "epics", "tickets" or "updates".');
  if (epics.length + tickets.length + updates.length > 50) errors.push("Send at most 50 epics, tickets and updates combined per batch.");
  for (const e of epics) if (e && e.ref) epicRefs.add(String(e.ref));

  const person = (label, value, field) => {
    if (value === undefined || value === null || value === "") return null;
    const found = findPerson(people, value);
    if (!found)
      errors.push(
        `${label}: ${field} "${value}" is not a unique, verified identity in PEOPLE. Request op:users to resolve it, or ask the human to reconcile Team & Jira. Never omit a requested assignee to bypass this check.`,
      );
    return found;
  };

  const customFields = (value, label) => {
    if (value === undefined) return undefined;
    if (!value || typeof value !== "object" || Array.isArray(value)) { errors.push(`${label}: customFields must be an object of exact Jira field names to text or null.`); return {}; }
    for (const [key, text] of Object.entries(value)) if (!key.trim() || key.length > 255 || (text !== null && typeof text !== "string"))
      errors.push(`${label}: custom field names must be 1–255 characters and values text or null.`);
    return value;
  };

  const item = (raw, kind) => {
    const label = `${kind === "Epic" ? "Epic" : "Ticket"} ${raw?.ref ?? "(no ref)"}`;
    if (!raw || typeof raw !== "object") {
      errors.push(`${label} must be a JSON object.`);
      return null;
    }
    const ref = String(raw.ref ?? "").trim();
    if (!ref) errors.push(`${label} needs a "ref", your own short label such as "T1".`);
    else if (refs.has(ref)) errors.push(`The ref "${ref}" is used twice in this message.`);
    refs.add(ref);
    const summary = String(raw.summary ?? "").trim();
    if (!summary) errors.push(`${label} needs a "summary".`);
    for (const [field, max] of Object.entries(TEXT_LIMITS))
      if (raw[field] != null && String(raw[field]).length > max)
        errors.push(`${label}: "${field}" is longer than ${max.toLocaleString("en-US")} characters.`);
    const explicitAssignee = Object.hasOwn(raw, "assignee") || Object.hasOwn(raw, "assigneeJiraId");
    const assignee = explicitAssignee ? person(label, raw.assignee ?? raw.assigneeJiraId, "assignee") : me;
    if (assignee && (assignee.active === false || assignee.identityWarning)) errors.push(`${label}: reconcile ${assignee.name}'s Salesforce/Jira identity in Team & Jira before assigning.`);
    const reporter = person(label, raw.reporter, "reporter");
    let dueDate = raw.dueDate ? String(raw.dueDate) : "";
    let dueDateSource = raw.dueDateSource === "input" ? "input" : "suggested";
    let dueDateNote = raw.dueDateNote ? String(raw.dueDateNote) : "";
    if (dueDate && !validDate(dueDate))
      errors.push(`${label}: dueDate "${dueDate}" must be a real date written YYYY-MM-DD.`);
    if (!dueDate) ({ dueDate, dueDateSource, dueDateNote } = suggestedDueDate());
    const out = {
      ...(raw.customFields !== undefined ? {customFields: customFields(raw.customFields, label)} : {}),
      ref,
      summary,
      description: raw.description ? String(raw.description) : "",
      priority: raw.priority ? String(raw.priority) : "",
      dueDate,
      dueDateSource,
      dueDateNote,
      dependsOn: Array.isArray(raw.dependsOn) ? raw.dependsOn.join(", ") : raw.dependsOn ? String(raw.dependsOn) : "",
      assigneeId: assignee?.id || null,
      reporterId: reporter?.id || null,
      // For the review screen only.
      assigneeName: assignee?.name || "",
      issueType: kind === "Epic" ? "Epic" : String(raw.issueType || "Task"),
    };
    if (kind === "Epic") out.epicName = raw.epicName ? String(raw.epicName) : summary;
    else {
      if (/^epic$/i.test(out.issueType))
        errors.push(`${label} has issueType "Epic". Put epics in the "epics" list.`);
      const links = ["epicRef", "epicTicket", "epicKey"].filter((k) => raw[k]);
      if (links.length > 1) errors.push(`${label}: use only one of epicRef, epicTicket or epicKey.`);
      if (raw.epicRef) {
        if (!epicRefs.has(String(raw.epicRef)))
          errors.push(`${label}: epicRef "${raw.epicRef}" is not an epic in this message. Use epicTicket (TKT-…) or epicKey for an existing epic.`);
        out.epicRef = String(raw.epicRef);
      }
      if (raw.epicTicket) out.epicTicket = String(raw.epicTicket).toUpperCase();
      if (raw.epicKey) out.epicKey = String(raw.epicKey).toUpperCase();
    }
    return out;
  };

  const checkedEpics = epics.map((e) => item(e, "Epic")).filter(Boolean);
  const checkedTickets = tickets.map((t) => item(t, "Task")).filter(Boolean);
  const checkedUpdates = updates.map((u, i) => {
    const label = `Update ${i + 1} (${u?.target ?? "no target"})`;
    const target = String(u?.target ?? "").trim().toUpperCase();
    if (!target) errors.push(`${label} needs a "target": a Jira key or TKT ID.`);
    const changes = { ...(u?.changes && typeof u.changes === "object" ? u.changes : {}) };
    if ("customFields" in changes) customFields(changes.customFields, label);
    if ("assignee" in changes) {
      const found = person(label, changes.assignee, "assignee");
      changes.assigneeId = found?.id || null;
      changes.assignee = found ? `${found.name}${found.jiraId ? " (" + found.jiraId + ")" : ""}` : changes.assignee;
    }
    if (changes.dueDate && !validDate(String(changes.dueDate)))
      errors.push(`${label}: dueDate "${changes.dueDate}" must be a real date written YYYY-MM-DD.`);
    if (changes.statusCategory && !["To Do", "In Progress", "Done"].includes(changes.statusCategory))
      errors.push(`${label}: statusCategory must be "To Do", "In Progress" or "Done".`);
    const comments = (Array.isArray(u?.comments) ? u.comments : u?.comments ? [u.comments] : []).map((comment) => {
      if (typeof comment === "string") return comment;
      if (!comment || typeof comment.text !== "string" || !comment.text.trim()) {
        errors.push(`${label}: each comment needs nonempty text.`); return "";
      }
      const names = comment.mentionAliases || comment.mentions || [];
      if (!Array.isArray(names)) { errors.push(`${label}: mentionAliases must be a list of saved names or aliases.`); return comment.text; }
      const mentions = names.map((name) => {
        const found = person(label, typeof name === "string" ? name : name?.name, "mention");
        if (found && !found.jiraId) errors.push(`${label}: ${found.name} needs a confirmed Jira ID before mentioning them.`);
        return found ? {name: found.name, userId: found.jiraId} : null;
      }).filter(Boolean);
      return {text: comment.text, mentions};
    });
    if (!Object.keys(changes).length && !comments.length)
      errors.push(`${label} has no "changes" and no "comments".`);
    return { target, changes, comments, reason: u?.reason ? String(u.reason) : "" };
  });

  return {
    errors,
    batch: {
      ...(typeof message.batchId === "string" && message.batchId.trim() ? {batchId: message.batchId.trim()} : {}),
      projectKey: message.projectKey || projectKey || "",
      epics: checkedEpics,
      tickets: checkedTickets,
      updates: checkedUpdates,
    },
  };
}
