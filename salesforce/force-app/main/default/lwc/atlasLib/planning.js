import { localDate, validDate } from "./dates";

export const PLANNING_LANES = ["Backlog", "Next", "In progress", "Blocked", "Done"];
export function planningState(ticket) {
  const p = ticket.planning || {};
  return { ...p, lane: PLANNING_LANES.includes(p.lane) ? p.lane : "Backlog", blockerNote: p.blockerNote || "",
    dependencies: p.dependencies || [], followUp: p.followUp || "", snooze: p.snooze || "" };
}
export function planningLane(ticket) { return planningState(ticket).lane; }
export function reminderText(ticket, today = localDate(), window = 3) {
  const p = planningState(ticket);
  if (ticket.stage === "Archived" || p.lane === "Done" || (validDate(p.snooze) && p.snooze > today)) return "";
  const notes = [];
  for (const [label, date] of [["Due", ticket.dueDate], ["Follow up", p.followUp]]) {
    if (!validDate(date)) continue;
    const days = (Date.parse(date + "T00:00:00Z") - Date.parse(today + "T00:00:00Z")) / 86400000;
    if (days <= window) notes.push(`${label} ${date}${days < 0 ? " (overdue)" : days === 0 ? " (today)" : " (soon)"}`);
  }
  return notes.join(" · ");
}
export function epicExportPlan(visible, all) {
  const drafts = visible.filter((t) => t.stage === "Draft");
  const epics = new Map(drafts.filter((t) => t.issueType === "Epic").map((t) => [t.id, t]));
  const blocked = [];
  for (const t of drafts.filter((t) => t.issueType !== "Epic")) {
    const parent = all.find((e) => e.id === t.epicId);
    if (parent && !parent.jiraKey) {
      if (parent.stage === "Draft") epics.set(parent.id, parent);
      blocked.push(t);
    } else if (t.epicId && !t.epicKey && !parent?.jiraKey) blocked.push(t);
  }
  const phase = epics.size ? "epics" : "children";
  return { phase, tickets: epics.size ? [...epics.values()] : drafts.filter((t) => t.issueType !== "Epic" && !blocked.includes(t)), blocked };
}
export function refreshJql(tickets) {
  const keys = [...new Set(tickets.map((t) => t.jiraKey).filter((k) => /^[A-Z][A-Z0-9_]*-\d+$/.test(k || "")))];
  return keys.length ? `key in (${keys.map((k) => '"' + k + '"').join(", ")}) ORDER BY key ASC` : "";
}

/** Stable per-item origins; bounded create pass then bounded relationship pass. */
export function legacyChunks(workspace, size = 50) {
  const task = workspace.taskAtlas || workspace;
  const workspaceId = workspace.workspace || workspace.workspaceId;
  if (typeof workspaceId !== "string" || !workspaceId.trim()) throw new Error("Import this backup through Library & recovery to establish its stable workspace identity.");
  if (!Array.isArray(task.items)) throw new Error("This backup has no taskAtlas.items.");
  const ids = task.items.map((t) => t.id);
  if (ids.some((id) => typeof id !== "string" || !id) || new Set(ids).size !== ids.length) throw new Error("Legacy tickets need unique stable IDs.");
  const keys = task.items.map((t) => t.key?.toUpperCase()).filter(Boolean);
  if (new Set(keys).size !== keys.length) throw new Error("Duplicate legacy Jira keys. No tickets imported.");
  const chunks = [];
  const bound = Math.max(1, Math.min(50, size));
  for (const phase of ["records", "links"]) {
    for (let i = 0; i < task.items.length; i += bound) {
      const items = task.items.slice(i, i + bound);
      const selected = new Set(items.map((t) => t.id));
      chunks.push({ workspaceId, phase, items, settings: task.settings || {}, userMappings: task.userMappings || [],
        jiraUpdates: (task.jiraUpdates || []).filter((u) => selected.has(u.ticketId)),
        batches: (task.batches || []).filter((b) => b.ids?.some((id) => selected.has(id))) });
    }
  }
  return chunks;
}
