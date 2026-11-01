import { LightningElement, api } from "lwc";
import boardPage from "@salesforce/apex/Atlas_Tickets.boardPage";
import getTicket from "@salesforce/apex/Atlas_Tickets.getTicket";
import saveTicket from "@salesforce/apex/Atlas_Tickets.saveTicket";
import setStage from "@salesforce/apex/Atlas_Tickets.setStage";
import completeUpdatePart from "@salesforce/apex/Atlas_Tickets.completeUpdatePart";
import saveExport from "@salesforce/apex/Atlas_Tickets.saveExport";
import beginImport from "@salesforce/apex/Atlas_Tickets.beginImport";
import importJira from "@salesforce/apex/Atlas_Tickets.importJira";
import migrateLegacy from "@salesforce/apex/Atlas_Tickets.importLegacy";
import ticketFiles from "@salesforce/apex/Atlas_Tickets.ticketFiles";
import prepareTicketWrite from "@salesforce/apex/Atlas_JiraWrites.prepareTicketWrite";
import { downloadFile, errorMessage, exportCSV, importRows, localDate, parseCSV, updateText,
  planningState, planningLane, reminderText, epicExportPlan, refreshJql, legacyChunks, rawExportCSV, reviewImportRows } from "c/atlasLib";

import { restoreLibrary, readLibrary, inOrder } from "c/atlasStorage";

// Manual planning lanes remain editable; only the mirrored Jira status groups the board.
const LANES = ["Backlog", "Next", "In progress", "Blocked", "Done"];
const JIRA_STATUSES = ["Registered", "Not Started", "Planning", "Working", "Waiting On Others", "On Hold", "Ready To Release", "Completed", "Cancelled"];
const OTHER_STATUS = "Other / no Jira status";
const IMPORT_CHUNK = 50;
const fileURL = (id) => `/sfc/servlet.shepherd/version/download/${id}`;
// Getters run on every render; the board is rebuilt only when something it reads changes.
const boardCache = new WeakMap();
const remember = (owner, key, inputs, build) => {
  const cache = boardCache.get(owner) || {};
  boardCache.set(owner, cache);
  const hit = cache[key];
  if (hit && hit.inputs.length === inputs.length && hit.inputs.every((value, i) => value === inputs[i])) return hit.value;
  const value = build();
  cache[key] = { inputs, value };
  return value;
};
const object = (value) => !!value && typeof value === "object" && !Array.isArray(value);
const UNRESOLVED_JIRA_STATES = new Set(["loading", "reviewed", "queued", "unknown"]);
const JIRA_WRITE_HISTORY = 20;
const validJiraWrite = (write) => object(write) && typeof write.id === "string" && !!write.id
  && typeof write.ticketId === "string" && !!write.ticketId && typeof write.part === "string" && !!write.part
  && (write.updateId === null || typeof write.updateId === "string")
  && (typeof write.expectedVersion === "string" || typeof write.expectedVersion === "number")
  && typeof write.contextLabel === "string" && typeof write.state === "string";
const validImport = (review) => object(review) && Array.isArray(review.rows) && Array.isArray(review.skipped) && object(review.totals)
  && Number.isInteger(review.next) && review.next >= 0 && review.next <= review.rows.length
  && (review.next === review.rows.length || review.next % IMPORT_CHUNK === 0)
  && review.rows.every((row) => object(row) && typeof row.key === "string" && row.key && Array.isArray(row.candidates) && row.candidates.every((candidate) => object(candidate) && typeof candidate.id === "string"));
const validEditor = (editor) => object(editor) && object(editor.ticket) && typeof editor.ticket.id === "string" && object(editor.editing) && typeof editor.savedEditing === "string";
const validExport = (plan) => {
  if (!object(plan) || !["epics", "children", "snapshot"].includes(plan.phase) || !Array.isArray(plan.tickets) || !plan.tickets.every((ticket) => object(ticket) && typeof ticket.id === "string") || !Array.isArray(plan.blocked)) return false;
  if (!plan.pending) return true;
  try { return object(plan.pending) && typeof plan.pending.exportJson === "string" && typeof JSON.parse(plan.pending.exportJson)?.csv === "string"; }
  catch { return false; }
};

export default class AtlasTickets extends LightningElement {
  @api boot;
  @api settings;
  tickets = [];
  loaded = false;
  owner = "team";
  search = "";
  epic = "";
  showArchived = false;
  busy = false;
  error;
  message;
  selected;
  editing;
  savedEditing = "";
  get editorDirty() { return !!this.selected && JSON.stringify(this.editing) !== this.savedEditing; }
  requireSavedEditor() {
    if (!this.editorDirty) return true;
    this.error = "Save the ticket edits before closing, opening another ticket, or confirming a checklist item. Your edits have been kept.";
    return false;
  }
  @api refresh() { return this.load(); }
  exporting;
  importing;
  receipts = [];
  files = [];
  filesCursor;
  loadGeneration = 0;
  ticketFetchGeneration = 0;
  importOffset = 0;
  pendingRecoveries = [];
  jiraWrites = [];
  createdJiraTicketIds = [];
  jiraWriteRecoveryReady = true;
  @api get recoveryDraft() { return this.pendingRecoveries[0]; }
  set recoveryDraft(value) {
    if (value) this.pendingRecoveries = [...this.pendingRecoveries, value];
    if (this.recoveryHydrated) this.cacheRecovery();
  }
  get hasRecovery() { return this.pendingRecoveries.length > 0; }
  get importLocked() { return this.busy || !!this.importing?.manifestId; }
  get importPrevious() { return this.importOffset > 0; }
  get importMore() { return this.importOffset + IMPORT_CHUNK < (this.importing?.rows.length || 0); }
  get hasJiraWrites() { return this.jiraWrites.length > 0; }
  get visibleJiraWrites() {
    const recent = this.jiraWrites.filter((write) => !UNRESOLVED_JIRA_STATES.has(write.operation?.state)).slice(-3);
    const shown = new Set(recent.map((write) => write.id));
    const active = this.jiraWrites.filter((write) => UNRESOLVED_JIRA_STATES.has(write.operation?.state) && !shown.has(write.id));
    return [...recent, ...active];
  }
  get jiraReviewDisabled() { return this.busy || !this.liveWritesEnabled || !this.jiraWriteRecoveryReady; }
  get hasExternalJiraCredential() { return !!this.settings?.jira?.externalCredential?.trim(); }
  get liveWritesEnabled() {
    const jira = this.settings?.jira || {};
    return this.hasExternalJiraCredential && !!jira.namedCredential?.trim() && !!jira.siteUrl?.trim() && jira.writeEnabled === true;
  }
  get hasUnresolvedJiraWrite() { return this.jiraWrites.some((write) => UNRESOLVED_JIRA_STATES.has(write.operation?.state)); }
  get selectedHasUnresolvedJiraWrite() {
    return this.jiraWrites.some((write) => write.ticketId === this.selected?.id && UNRESOLVED_JIRA_STATES.has(write.operation?.state));
  }
  get editorDisabled() { return this.busy || this.selectedHasUnresolvedJiraWrite; }
  get jiraWriteAvailability() {
    if (!this.settings?.jira?.writeEnabled) return "Direct Jira writes are disabled. The existing CSV workflow remains available.";
    if (!this.liveWritesEnabled) return "Direct writes are not ready. Complete the Jira credential names and site address under Team & Jira; live failures are not replaced by CSV.";
    if (!this.jiraWriteRecoveryReady) return "Browser recovery is unavailable, so Atlas will not allow an approval that cannot be recovered safely.";
    if (this.hasUnresolvedJiraWrite) return "Resolve the saved Jira write above before preparing another one. Queued or unknown outcomes are never sent again automatically.";
    return "Each direct write is previewed exactly and sent only after your explicit approval.";
  }
  get jiraWriteButtonDisabled() { return this.busy || !this.liveWritesEnabled || !this.jiraWriteRecoveryReady || this.hasUnresolvedJiraWrite || this.editorDirty; }
  get creationAlreadyConfirmed() { return !!this.selected && this.createdJiraTicketIds.includes(this.selected.id); }
  get creationPreviewDisabled() { return this.jiraWriteButtonDisabled || !this.selected || !!this.selected.jiraKey || this.creationAlreadyConfirmed; }
  get creationDisabledReason() {
    if (this.editorDirty) return "Save the local ticket edits before preparing an exact Jira preview.";
    if (this.creationAlreadyConfirmed) return "Atlas has a confirmed Jira creation for this ticket. Link its Jira key before considering another creation.";
    if (this.selected?.jiraKey) return "This ticket already has a Jira key; use its pending update parts for direct edits.";
    return "";
  }
  get importPageLabel() { return `Review rows ${this.importing?.rows.length ? this.importOffset + 1 : 0}–${Math.min(this.importOffset + IMPORT_CHUNK, this.importing?.rows.length || 0)} of ${this.importing?.rows.length || 0}. Choices lock once import begins; retries use the same reviewed rows.`; }
  previousImportPage() { this.importOffset = Math.max(0, this.importOffset - IMPORT_CHUNK); }
  nextImportPage() { if (this.importMore) this.importOffset += IMPORT_CHUNK; }
  async saveRecovery(data, title) {
    const dataJson = JSON.stringify({ type: "atlas-jira-operation", version: 1, ...data });
    const bytes = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(dataJson));
    const key = Array.from(new Uint8Array(bytes), (n) => n.toString(16).padStart(2, "0")).join("");
    const saved = await restoreLibrary({ title, kind: "draft", dataJson }, `jira:${key}`);
    this.addReceipt(saved.versionId, title);
    return { id: saved.id, versionId: saved.versionId };
  }
  async preserveImport() {
    const current = this.importing;
    const { source, ...review } = current;
    if (source) return source;
    // Pin the payload before awaiting: a later choice must never inherit an older receipt.
    const raw = JSON.stringify(review);
    const saved = await this.saveRecovery({ operation: "import", review: JSON.parse(raw) }, "Atlas Jira import review");
    const { source: ignored, ...latest } = this.importing || {};
    if (this.importing === current && JSON.stringify(latest) === raw) current.source = saved;
    this.cacheRecovery();
    return saved;
  }
  saveImportReview() {
    return this.guard(async () => {
      await this.preserveImport();
      this.message = "Review saved privately. Reconciliation choices also autosave. Open its draft in Library & recovery to resume on another device.";
    });
  }
  async preserveImportProgress() {
    const { source, next, totals } = this.importing;
    await this.saveRecovery({ operation: "import-progress", source, next, totals, receipts: this.receipts },
      next === this.importing.rows.length ? "Atlas Jira import completed" : "Atlas Jira import progress");
  }
  resumeRecovery() {
    if (!this.requireSavedEditor()) return;
    return this.guard(async () => {
      if (this.importing || this.exporting) throw Error("Save and close the current Jira review before opening another. The incoming recovery is queued.");
      let data = JSON.parse(JSON.stringify(this.pendingRecoveries[0]));
      const progress = data.operation === "import-progress" ? data : null;
      if (progress) {
        const row = await readLibrary({ recordId: progress.source?.id, versionId: progress.source?.versionId });
        data = JSON.parse(row.dataJson);
      }
      if (data.type !== "atlas-jira-operation" || data.version !== 1) throw Error("Unsupported Jira recovery draft.");
      if (data.operation === "import") {
        const review = data.review;
        if (!validImport(review)) throw Error("Invalid import review; nothing applied.");
        if (progress) {
          if (!Number.isInteger(progress.next) || progress.next < 0 || progress.next > review.rows.length ||
            (progress.next !== review.rows.length && progress.next % IMPORT_CHUNK !== 0) || !progress.totals ||
            !review.manifestId) throw Error("Invalid import checkpoint; nothing applied.");
          review.next = progress.next; review.totals = progress.totals; review.source = progress.source;
        }
        this.importing = review; this.importOffset = 0;
      } else if (data.operation === "export") {
        const plan = data.plan, request = JSON.parse(plan?.pending?.exportJson || "null");
        if (!request || typeof request.csv !== "string" || !validExport(plan)) throw Error("Invalid export recovery; nothing applied.");
        this.exporting = plan;
      } else if (data.operation === "editor") {
        if (!validEditor(data)) throw Error("Invalid saved ticket editor.");
        this.selected = data.ticket; this.editing = data.editing; this.savedEditing = data.savedEditing;
        this.files = []; this.filesCursor = null;
      } else throw Error("Unsupported Jira operation.");
      for (const r of progress?.receipts || []) this.addReceipt(r.id, r.label);
      this.pendingRecoveries = this.pendingRecoveries.slice(1);
      this.message = "Saved work restored for review. Nothing has been applied. Confirm to resume; committed chunks and exact exports reuse their receipts.";
    });
  }
  saveAndCloseEditor() {
    return this.guard(async () => {
      await this.saveRecovery({ operation: "editor", ticket: this.selected, editing: this.editing, savedEditing: this.savedEditing }, "Atlas saved ticket edits");
      this.selected = null;
      this.message = "Ticket edits saved privately as a Library draft, not applied to the ticket. Restore the draft to continue; version conflicts still require review.";
    });
  }

  recoveryStatus = "";
  recoveryTimer;
  recoveryQueue = Promise.resolve();
  recoverySaved = "";
  recoveryHydrated = false;
  connected = true;
  get recoveryKey() { return this.boot?.org?.id && this.boot?.user?.id ? `atlas-tickets:${this.boot.org.id}:${this.boot.user.id}` : null; }
  recoveryData() {
    return { version: 1, importing: this.importing || null, exporting: this.exporting || null,
      editor: this.editorDirty ? { ticket: this.selected, editing: this.editing, savedEditing: this.savedEditing } : null,
      pendingRecoveries: this.pendingRecoveries, receipts: this.receipts, importOffset: this.importOffset,
      jiraWrites: this.jiraWrites.map(({ id, ticketId, part, updateId, expectedVersion, contextLabel, operation }) => ({ id, ticketId, part, updateId, expectedVersion, contextLabel, state: operation?.state || "loading" })),
      createdJiraTicketIds: this.createdJiraTicketIds };
  }
  cacheRecovery() {
    if (!this.connected || !this.recoveryKey) return false;
    try {
      sessionStorage.setItem(this.recoveryKey, JSON.stringify(this.recoveryData()));
      this.jiraWriteRecoveryReady = true;
      return true;
    } catch {
      this.jiraWriteRecoveryReady = false;
      this.recoveryStatus = "Browser recovery unavailable. Keep this tab open until private Salesforce recovery is saved; live Jira approvals are disabled until the operation ID can be stored.";
      return false;
    }
  }
  scheduleRecovery() {
    clearTimeout(this.recoveryTimer);
    if (!this.connected || !this.recoveryKey) return;
    this.recoveryStatus = "Saving private recovery draft… Ticket records are unchanged.";
    this.cacheRecovery();
    this.recoveryTimer = setTimeout(() => this.flushRecovery().catch(() => {}), 750);
  }
  flushRecovery() {
    clearTimeout(this.recoveryTimer);
    const snapshot = JSON.parse(JSON.stringify(this.recoveryData()));
    const raw = JSON.stringify({ importing: snapshot.importing, editor: snapshot.editor });
    const work = this.recoveryQueue.then(async () => {
      if (raw === this.recoverySaved) return;
      if (snapshot.importing) {
        const { source, ...review } = snapshot.importing;
        await this.saveRecovery({ operation: "import", review }, "Atlas Jira import review");
      }
      if (snapshot.editor) await this.saveRecovery({ operation: "editor", ...snapshot.editor }, "Atlas saved ticket edits");
      this.recoverySaved = raw;
      const latest = this.recoveryData();
      if (this.connected && raw === JSON.stringify({ importing: latest.importing, editor: latest.editor }))
        this.recoveryStatus = snapshot.importing || snapshot.editor ? "Private recovery draft saved in Salesforce. Ticket changes still require confirmation." : "";
    });
    this.recoveryQueue = work.catch((e) => {
      if (this.connected) this.recoveryStatus = "Private draft NOT saved: " + errorMessage(e) + ". Keep this tab open and retry saving.";
    });
    return work;
  }
  connectedCallback() {
    this.connected = true;
    if (this.recoveryHydrated) { this.load(); return; }
    try {
      const saved = this.recoveryKey && JSON.parse(sessionStorage.getItem(this.recoveryKey) || "null");
      if (saved) {
        if (saved.version !== 1 || !Array.isArray(saved.pendingRecoveries) || !saved.pendingRecoveries.every(object)
          || !Array.isArray(saved.receipts) || !saved.receipts.every((receipt) => object(receipt) && typeof receipt.id === "string" && typeof receipt.label === "string")) throw Error("Invalid recovery data");
        if (saved.importing && !validImport(saved.importing)) throw Error("Invalid import review");
        if (saved.exporting && !validExport(saved.exporting)) throw Error("Invalid export review");
        if (saved.editor && !validEditor(saved.editor)) throw Error("Invalid ticket editor");
        if (saved.importOffset != null && (!Number.isInteger(saved.importOffset) || saved.importOffset < 0)) throw Error("Invalid review page");
        if (saved.jiraWrites != null && (!Array.isArray(saved.jiraWrites) || !saved.jiraWrites.every(validJiraWrite))) throw Error("Invalid saved Jira operation");
        if (saved.createdJiraTicketIds != null && (!Array.isArray(saved.createdJiraTicketIds) || !saved.createdJiraTicketIds.every((id) => typeof id === "string"))) throw Error("Invalid Jira creation history");
        this.importing = saved.importing; this.exporting = saved.exporting;
        if (saved.editor) { this.selected = saved.editor.ticket; this.editing = saved.editor.editing; this.savedEditing = saved.editor.savedEditing; }
        this.pendingRecoveries = [...saved.pendingRecoveries, ...this.pendingRecoveries];
        this.receipts = saved.receipts; this.importOffset = saved.importOffset || 0;
        this.jiraWrites = (saved.jiraWrites || []).map((write, index, writes) => ({ ...write,
          operation: { id: write.id, state: UNRESOLVED_JIRA_STATES.has(write.state) || index >= writes.length - 3 ? "loading" : write.state } }));
        this.createdJiraTicketIds = saved.createdJiraTicketIds || [];
        this.jiraWriteRecoveryReady = true;
        this.recoveryStatus = this.jiraWrites.length
          ? "Recovered saved Jira operation IDs. Atlas is checking their status; no Jira request will be sent again automatically."
          : "Recovered unfinished work from this tab. Review it before confirming; nothing was applied automatically.";
      }
    } catch { this.jiraWriteRecoveryReady = false; this.recoveryStatus = "Browser recovery could not be read. Private saved drafts remain in Library & recovery; do not retry an unknown Jira write."; }
    this.recoveryHydrated = true;
    this.load();
  }
  disconnectedCallback() {
    this.loadGeneration++;
    this.cacheRecovery();
    this.flushRecovery().catch(() => {});
    this.connected = false;
  }
  async load() {
    const generation = ++this.loadGeneration;
    try {
      const records = [], cursors = new Set(), ids = new Set();
      let afterId = null;
      do {
        const page = await boardPage({ includeArchived: this.showArchived, afterId, pageSize: 200 });
        if (generation !== this.loadGeneration) return;
        for (const ticket of page.tickets) {
          if (ids.has(ticket.id)) throw Error("Ticket paging repeated a record. The previous board remains; refresh to retry.");
          ids.add(ticket.id); records.push(ticket);
        }
        afterId = page.nextCursor;
        if (afterId && cursors.has(afterId)) throw Error("Ticket paging repeated a cursor. Refresh to retry.");
        cursors.add(afterId);
      } while (afterId);
      this.tickets = records;
      this.loaded = true;
      this.error = null;
    } catch (e) { if (generation === this.loadGeneration) this.error = errorMessage(e); }
  }
  get people() { return this.boot?.people || []; }
  get me() { return this.people.find((p) => p.isMe); }
  get reports() { return this.people.filter((p) => p.isMyReport && p.active !== false); }
  get ownerOptions() {
    return [{ label: "All (me and my direct reports)", value: "team" }, { label: "Me", value: "me" },
      ...this.reports.map((p) => ({ label: p.name, value: p.id })), { label: "Everyone", value: "everyone" }, { label: "Unassigned", value: "unassigned" }];
  }
  get epicOptions() {
    return [{ label: "All epics", value: "" }, ...this.tickets.filter((t) => t.issueType === "Epic").map((e) => ({ label: `${e.jiraKey || e.atlasId} ${e.summary}`, value: e.id }))];
  }
  ownerIds() {
    if (this.owner === "me") return new Set([this.me?.id]);
    if (this.owner === "team") return new Set([this.me?.id, ...this.reports.map((p) => p.id)]);
    return this.owner === "everyone" || this.owner === "unassigned" ? null : new Set([this.owner]);
  }
  get visible() {
    return remember(this, "visible", [this.tickets, this.owner, this.search, this.epic, this.boot?.people], () => {
      const ids = this.ownerIds(), text = this.search.trim().toLowerCase();
      const epic = this.tickets.find((t) => t.id === this.epic);
      return this.tickets.filter((t) =>
        (this.owner === "unassigned" ? !t.assigneeId : !ids || ids.has(t.assigneeId)) &&
        (!epic || t.id === epic.id || t.epicId === epic.id || (epic.jiraKey && t.epicKey === epic.jiraKey)) &&
        (!text || [t.summary, t.atlasId, t.jiraKey, t.assigneeName, t.epicSummary].some((v) => v?.toLowerCase().includes(text))));
    });
  }
  get columns() {
    const today = localDate();
    return remember(this, "columns", [this.visible, this.tickets, today], () => this.buildColumns(today));
  }
  buildColumns(today) {
    // Each dependency used to scan every ticket; one lookup table serves the whole board. The first ticket with a key wins, as before.
    const byKey = new Map();
    for (const other of this.tickets) {
      for (const key of [other.id, other.atlasId, other.jiraKey, other.planning?.legacyId]) if (key && !byKey.has(key)) byKey.set(key, other);
    }
    const groups = new Map([...JIRA_STATUSES, OTHER_STATUS].map((status) => [status, []]));
    for (const t of this.visible) {
      const p = planningState(t), reminder = reminderText(t, today);
      const dependencies = p.dependencies.map((id) => {
        const linked = byKey.get(id);
        return linked ? `${linked.jiraKey || linked.atlasId} (${planningLane(linked)})` : `${id} (unresolved)`;
      }).join(", ");
      const status = JIRA_STATUSES.includes(t.jiraStatus) ? t.jiraStatus : OTHER_STATUS;
      groups.get(status).push({ ...t, title: `${t.jiraKey || t.atlasId} · ${t.issueType}`,
        who: p.unresolvedAssignee ? `Reconcile: ${p.unresolvedAssignee} · current: ${t.assigneeName || "Unassigned"}` : t.assigneeName || "Unassigned",
        due: t.dueDate ? `Due ${t.dueDate}` : "", status: `Jira mirror: ${t.stage}${t.jiraStatus ? " · " + t.jiraStatus : ""}`,
        reminder, blocker: p.blockerNote, dependencies, followUp: p.followUp ? `Follow up ${p.followUp}` : "", snooze: p.snooze ? `Reminders snoozed until ${p.snooze}` : "",
        pending: t.pendingCount ? `${t.pendingCount} update(s) to copy into Jira` : "",
        className: "atlas-ticket" + (reminder.includes("overdue") ? " atlas-late" : "") + (t.issueType === "Epic" ? " atlas-epic" : ""),
        typeClass: "atlas-pill " + (t.issueType === "Epic" ? "atlas-pill_epic" : t.issueType === "Bug" ? "atlas-pill_danger" : "atlas-pill_accent"),
        code: t.jiraKey || t.atlasId, mirror: t.jiraStatus?.trim() || "No Jira status" });
    }
    const statuses = groups.get(OTHER_STATUS).length ? [...JIRA_STATUSES, OTHER_STATUS] : JIRA_STATUSES;
    return statuses.map((key) => ({ key, label: key, cards: groups.get(key), count: groups.get(key).length,
      empty: groups.get(key).length === 0, className: "atlas-column atlas-column_" + (key === OTHER_STATUS ? "other" : key.toLowerCase().replace(/\s+/g, "-")) }));
  }
  get refreshQuery() { return refreshJql(this.visible); }
  get archivedLabel() { return this.showArchived ? "Hide archived" : "Show archived"; }
  get visibleCount() { const n = this.visible.length; return `${n} ticket${n === 1 ? "" : "s"}`; }
  get noPeople() { return !this.me; }
  get laneOptions() { return LANES.map((value) => ({ label: value, value })); }
  get hasReceipts() { return this.receipts.length > 0; }
  handleOwner(event) { this.owner = event.detail.value; }
  handleSearch(event) { this.search = event.detail.value || ""; }
  handleEpic(event) { this.epic = event.detail.value; }
  async toggleArchived() { this.showArchived = !this.showArchived; await this.load(); }
  async guard(work) {
    if (this.busy) return;
    this.busy = true; this.error = null;
    try { return await work(); } catch (e) { this.error = errorMessage(e); return undefined; }
    finally { this.busy = false; this.cacheRecovery(); }
  }
  addReceipt(id, label) {
    if (id && !this.receipts.some((r) => r.id === id)) this.receipts = [...this.receipts, { id, label, url: fileURL(id) }];
  }
  async prepareJiraWrite({ ticketId, part, updateId, expectedVersion, contextLabel }) {
    if (!this.liveWritesEnabled) { this.error = "Live Jira writes are not enabled in the saved Jira settings. No request was sent."; return; }
    if (!this.recoveryKey) { this.error = "The Salesforce org and user recovery identity is unavailable. No Jira request was prepared."; return; }
    if (this.editorDirty) { this.error = "Save the local ticket edits before preparing an exact Jira preview. No request was sent."; return; }
    if (this.hasUnresolvedJiraWrite) { this.error = "Resolve the saved Jira write before preparing another one. No request was sent."; return; }
    await this.guard(async () => {
      const review = JSON.parse(await prepareTicketWrite({ ticketId, part, updateId, expectedVersion }));
      if (!object(review) || typeof review.id !== "string" || !review.id || typeof review.state !== "string")
        throw new Error("Jira returned an invalid write preview. No request was sent.");
      const record = { id: review.id, ticketId, part, updateId, expectedVersion, contextLabel, operation: review };
      this.jiraWrites = [...this.jiraWrites.filter((write) => write.id !== record.id), record].slice(-JIRA_WRITE_HISTORY);
      if (part === "create" && review.state === "succeeded" && !this.createdJiraTicketIds.includes(ticketId))
        this.createdJiraTicketIds = [...this.createdJiraTicketIds, ticketId];
      if (!this.cacheRecovery()) throw new Error("The preview was prepared, but this browser could not save its operation ID. Approval is disabled; do not retry a write until recovery is available.");
      if (review.state === "reviewed") this.message = `Exact Jira request prepared for ${contextLabel}. Nothing has been sent. Review the request and approve it explicitly.`;
      else if (review.state === "queued") this.message = `Recovered the existing queued Jira operation for ${contextLabel}. Jira has not confirmed completion; Atlas did not send it again.`;
      else if (review.state === "succeeded") this.message = `Recovered the existing successful Jira operation for ${contextLabel}. Atlas did not send it again.`;
      else if (review.state === "unknown") this.message = `Recovered the existing Jira operation for ${contextLabel}, but its outcome is unknown. Do not send it again.`;
      else if (review.state === "failed") this.message = `Recovered the existing failed Jira operation for ${contextLabel}. Review its result before preparing any new request.`;
      else if (review.state === "invalidated") this.message = `The existing Jira preview for ${contextLabel} is no longer valid. No request was sent.`;
      else this.message = `Recovered the existing Jira operation for ${contextLabel} in state “${review.state}”. Atlas did not send it again.`;
    });
  }
  previewTicketCreation() {
    const ticket = this.selected;
    if (!ticket) return;
    return this.prepareJiraWrite({ ticketId: ticket.id, part: "create", updateId: null, expectedVersion: ticket.version,
      contextLabel: `creation of ${ticket.atlasId}` });
  }
  previewUpdatePart(event) {
    const { updateId, part, contextLabel } = event.currentTarget.dataset;
    if (!this.selected) return;
    return this.prepareJiraWrite({ ticketId: this.selected.id, part, updateId, expectedVersion: this.selected.version, contextLabel });
  }
  async handleJiraWriteChanged(event) {
    const operation = event.detail?.operation;
    const prior = this.jiraWrites.find((write) => write.id === operation?.id);
    if (!prior || !operation) return;
    this.jiraWrites = this.jiraWrites.map((write) => write.id === operation.id ? { ...write, operation } : write);
    if (prior.part === "create" && operation.state === "succeeded" && !this.createdJiraTicketIds.includes(prior.ticketId))
      this.createdJiraTicketIds = [...this.createdJiraTicketIds, prior.ticketId];
    this.cacheRecovery();
    if (operation.state !== "succeeded" || prior.operation?.state === "succeeded") return;
    if (operation.result?.mirrorSynced === true) this.message = `Jira confirmed ${prior.contextLabel}; Atlas updated the Salesforce ticket mirror.`;
    else if (operation.result?.mirrorSynced === false) this.message = `Jira confirmed ${prior.contextLabel}, but Atlas could not update the Salesforce mirror. Do not resend this Jira write; review its result above and reconcile the ticket locally.`;
    else this.message = `Jira confirmed ${prior.contextLabel} succeeded. Review the operation result above.`;
    try {
      if (this.selected?.id === prior.ticketId && !this.editorDirty) await this.fetchTicket(prior.ticketId);
      await this.load();
    } catch (e) {
      this.message += ` The Jira write remains confirmed, but the ticket could not be refreshed: ${errorMessage(e)}`;
    }
  }
  reviewProgress() {
    const label = this.ownerOptions.find((o) => o.value === this.owner)?.label || "my team";
    this.dispatchEvent(new CustomEvent("openconversation", { detail: { draft: { mode: "Task", title: `Progress review: ${label}`.slice(0, 80),
      request: `Review progress for ${label} over the last two weeks using their open and completed Atlas tickets and recent Salesforce activity. Cite imported snapshot dates, blockers, dependencies, due dates and follow-ups. Do not treat Updated as completion evidence. Propose field updates and separate comments only where supported by evidence.` } } }));
  }
  async openTicket(event) {
    if (!this.requireSavedEditor()) return;
    await this.guard(() => this.fetchTicket(event.currentTarget.dataset.id));
  }
  async fetchTicket(id) {
      const generation = ++this.ticketFetchGeneration;
      const t = await getTicket({ ticketId: id });
      if (generation !== this.ticketFetchGeneration || !this.connected) return;
      this.selected = { ...t, updates: (t.pendingUpdates || []).map((u, updateIndex) => ({ ...u, text: updateText(u),
        pending: u.status === "pending", by: `${u.createdBy || ""} ${u.created || ""}`, parts: [
          ...Object.entries(u.changes || {}).map(([field, value]) => {
            const partId = `field:${field}`;
            const priorSuccessWithoutMirror = this.jiraWrites.some((write) => write.ticketId === t.id && write.updateId === u.id && write.part === partId
              && write.operation?.state === "succeeded" && write.operation.result?.mirrorSynced === false && !write.resolvedInAtlas);
            const liveWritePending = this.jiraWrites.some((write) => write.ticketId === t.id && write.updateId === u.id && write.part === partId
              && UNRESOLVED_JIRA_STATES.has(write.operation?.state));
            const label = `${field}: ${value ?? "(clear)"}`;
            const finished = u.status !== "pending" || ["done", "dismissed"].includes(u.fieldStatus?.[field]);
            const previewDisabled = !this.liveWritesEnabled || !this.jiraWriteRecoveryReady || this.hasUnresolvedJiraWrite || this.editorDirty
              || finished || liveWritePending || priorSuccessWithoutMirror;
            return { id: partId, label, previewLabel: `Preview update ${updateIndex + 1}: ${label} in Jira`, previewBlocked: priorSuccessWithoutMirror,
              previewDisabled, actionDisabled: finished || liveWritePending, liveWritePending, finished, state: u.fieldStatus?.[field] || (u.status !== "pending" ? u.status : "pending") };
          }),
          ...(Array.isArray(u.comments) ? u.comments : []).map((c, i) => {
            const partId = `comment:${i}`;
            const priorSuccessWithoutMirror = this.jiraWrites.some((write) => write.ticketId === t.id && write.updateId === u.id && write.part === partId
              && write.operation?.state === "succeeded" && write.operation.result?.mirrorSynced === false && !write.resolvedInAtlas);
            const liveWritePending = this.jiraWrites.some((write) => write.ticketId === t.id && write.updateId === u.id && write.part === partId
              && UNRESOLVED_JIRA_STATES.has(write.operation?.state));
            const label = `Comment ${i + 1}: ${typeof c === "string" ? c : c.text}`;
            const finished = u.status !== "pending" || ["done", "dismissed"].includes(c.status);
            const previewDisabled = !this.liveWritesEnabled || !this.jiraWriteRecoveryReady || this.hasUnresolvedJiraWrite || this.editorDirty
              || finished || liveWritePending || priorSuccessWithoutMirror;
            return { id: partId, label, previewLabel: `Preview update ${updateIndex + 1}: ${label} in Jira`, previewBlocked: priorSuccessWithoutMirror,
              previewDisabled, actionDisabled: finished || liveWritePending, liveWritePending, finished, state: c.status || (u.status !== "pending" ? u.status : "pending") };
          }),
        ] })), hasConversation: !!t.conversationId };
      const p = planningState(t);
      this.editing = { summary: t.summary || "", description: t.description || "", priority: t.priority || "", dueDate: t.dueDate || "", assigneeId: t.assigneeId || "", reporterId: t.reporterId || "", jiraKey: t.jiraKey || "",
        customFieldsJson: JSON.stringify(t.planning?.customFields || {}, null, 2),
        lane: p.lane, blockerNote: p.blockerNote, dependencies: p.dependencies.join(", "), followUp: p.followUp, snooze: p.snooze,
        reconcileAssignee: false, reconcileReporter: false, epicId: t.epicId || "", epicKey: t.epicId ? "" : t.epicKey || "" };
      this.savedEditing = JSON.stringify(this.editing);
      this.files = []; this.filesCursor = null;
      await this.loadFiles(generation);
  }
  async loadFiles(expectedGeneration = this.ticketFetchGeneration) {
    if (!this.selected) return;
    const ticketId = this.selected.id;
    const result = JSON.parse(await ticketFiles({ ticketId, afterId: this.filesCursor }));
    if (expectedGeneration !== this.ticketFetchGeneration || this.selected?.id !== ticketId) return;
    this.files = [...this.files, ...result.files.map((f) => ({ ...f, url: fileURL(f.id) }))];
    this.filesCursor = result.nextCursor;
  }
  get hasUpdates() { return this.selected?.updates.length > 0; }
  get hasFiles() { return this.files.length > 0; }
  get assigneeOptions() { return [{ label: "Unassigned", value: "" }, ...this.people.filter((p) => p.active !== false).map((p) => ({ label: p.name, value: p.id }))]; }
  get priorityOptions() { return [{ label: "None", value: "" }, ...(this.settings?.jira?.priorities || "").split(",").map((p) => p.trim()).filter(Boolean).map((value) => ({ label: value, value }))]; }
  get parentOptions() { return [{ label: "No parent", value: "" }, ...this.epicOptions.slice(1).filter((o) => o.value !== this.selected?.id)]; }
  get archiveLabel() { return this.selected?.stage === "Archived" ? "Unarchive" : "Archive"; }
  closeTicket() { if (!this.busy && this.requireSavedEditor()) { this.ticketFetchGeneration++; this.selected = null; this.cacheRecovery(); } }
  handleEdit(event) {
    if (this.busy || this.selectedHasUnresolvedJiraWrite) return;
    const field = event.target.name, value = event.target.type === "checkbox" ? event.target.checked : event.detail.value ?? "";
    this.editing = { ...this.editing, [field]: value };
    if (field === "epicId") this.editing.epicKey = "";
    if (field === "epicKey") this.editing.epicId = "";
    this.scheduleRecovery();
  }
  async saveSelected() {
    if (this.selectedHasUnresolvedJiraWrite) { this.error = "Resolve the saved Jira write before changing this ticket. Its preview is tied to the current ticket version."; return; }
    await this.guard(async () => {
      const { lane, blockerNote, dependencies, followUp, snooze, customFieldsJson, ...fields } = this.editing;
      const customFields = JSON.parse(customFieldsJson || "{}");
      if (!customFields || typeof customFields !== "object" || Array.isArray(customFields) || Object.values(customFields).some((v) => v !== null && typeof v !== "string")) throw new Error("Custom fields must be a JSON object of exact names to text or null.");
      const changes = { id: this.selected.id, expectedVersion: this.selected.version, ...fields, customFields,
        epicId: fields.epicId || "", epicKey: fields.epicId ? "" : (fields.epicKey || "").trim().toUpperCase(),
        planning: { lane, blockerNote, dependencies: dependencies.split(/[,\n]/).map((s) => s.trim()).filter(Boolean), followUp, snooze }, jiraKey: fields.jiraKey.trim().toUpperCase() };
      if (changes.dueDate !== (this.selected.dueDate || "")) changes.dueDateSource = "input";
      if (changes.jiraKey && !this.selected.jiraKey) changes.stage = "In Jira";
      await saveTicket({ ticketJson: JSON.stringify(changes) });
      this.selected = null;
      await this.load();
    });
  }
  async snoozeTomorrow() {
    if (this.busy || this.selectedHasUnresolvedJiraWrite) return;
    const tomorrow = new Date(); tomorrow.setDate(tomorrow.getDate() + 1);
    this.editing = { ...this.editing, snooze: localDate(tomorrow) };
    await this.saveSelected();
  }
  async archiveSelected() {
    if (this.selectedHasUnresolvedJiraWrite) { this.error = "Resolve the saved Jira write before changing this ticket's stage. Its preview is tied to the current ticket version."; return; }
    if (!this.requireSavedEditor()) return;
    await this.guard(async () => {
      const stage = this.selected.stage === "Archived" ? this.selected.jiraKey ? "In Jira" : "Draft" : "Archived";
      await setStage({ ticketIds: [this.selected.id], stage, batch: null, versionsJson: JSON.stringify({ [this.selected.id]: this.selected.version }) });
      this.selected = null; await this.load();
    });
  }
  async finishUpdate(event) {
    if (!this.requireSavedEditor()) return;
    const { id: updateId, part, done } = event.currentTarget.dataset;
    const ticketId = this.selected.id;
    const pendingWrite = this.jiraWrites.find((write) => write.ticketId === ticketId && write.updateId === updateId && write.part === part
      && UNRESOLVED_JIRA_STATES.has(write.operation?.state));
    if (pendingWrite) { this.error = "Resolve the reviewed Jira write before changing this checklist part. Atlas will not send it again automatically."; return; }
    await this.guard(async () => {
      await completeUpdatePart({ ticketId, updateId, part, done: done === "true", expectedVersion: this.selected.version });
      await Promise.all([this.load(), this.fetchTicket(ticketId)]);
    });
  }
  openConversation() { this.dispatchEvent(new CustomEvent("openconversation", { detail: { id: this.selected.conversationId } })); }

  startExport() {
    if (this.busy || !this.requireSavedEditor()) return;
    if (this.exporting) { this.error = "Finish or save and close the current export first. Its exact request has been kept."; return; }
    const plan = epicExportPlan(this.visible, this.tickets);
    this.exporting = { ...plan, tickets: plan.tickets.slice(0, 100), count: Math.min(100, plan.tickets.length), remaining: Math.max(0, plan.tickets.length - 100) };
    this.cacheRecovery();
    if (!plan.tickets.length) this.message = plan.blocked.length ? "Children are blocked until their epic Jira keys are confirmed. Open each epic and enter its Jira key, or import the epic results CSV." : "There are no eligible drafts in this view.";
  }
  get exportInfo() {
    if (this.exporting.phase === "snapshot") return "Exact raw Jira snapshot, including repeated original columns. This is an archive, not a Jira creation import.";
    return `${this.exporting.phase === "epics" ? "Step 1 — epics only" : "Step 3 — children with confirmed parents"}: ${this.exporting.count} ticket(s). ${this.exporting.blocked.length} child ticket(s) blocked. ${this.exporting.remaining} additional draft(s) remain for the next file.`;
  }
  cancelExport() {
    return this.guard(async () => {
      if (this.exporting?.pending) await this.preserveExport();
      this.exporting = null;
    });
  }
  async preserveExport() {
    const { source, ...plan } = this.exporting;
    if (!source) this.exporting.source = await this.saveRecovery({ operation: "export", plan }, "Atlas Jira exact export retry");
  }
  async downloadExport() {
    await this.guard(async () => {
      if (!this.exporting.pending) {
        // Up to 100 tickets: read six at a time instead of one after another.
        const full = await inOrder(this.exporting.tickets, 6, async (t) => {
          const current = await getTicket({ ticketId: t.id });
          if (current.version !== t.version) throw new Error(`${t.atlasId} changed. Reload and review the export again.`);
          return current;
        });
        const result = exportCSV(full, { people: this.people, mapping: this.settings?.mapping, me: this.me });
        const batch = `ATLAS-${new Date().toISOString().replace(/[-:.TZ]/g, "")}`;
        this.exporting.pending = { batch, warnings: result.warnings, exportJson: JSON.stringify({ phase: this.exporting.phase, batch, csv: result.csv,
          jiraIds: Object.fromEntries(full.flatMap((t) => [t.assigneeId, t.reporterId]).filter(Boolean).map((id) => [id, this.people.find((p) => p.id === id)?.jiraId || ""])),
          versions: Object.fromEntries(full.map((t) => [t.id, t.version])), parentKeys: Object.fromEntries(full.map((t) => [t.id, t.epicKey || ""])) }) };
      }
      this.cacheRecovery();
      await this.preserveExport();
      const { exportJson, batch, warnings = [] } = this.exporting.pending;
      const saved = JSON.parse(await saveExport({ exportJson }));
      this.addReceipt(saved.fileId, `${batch} exact CSV`); this.addReceipt(saved.receiptId, `${batch} export receipt`);
      downloadFile(this.template.querySelector("a.atlas-download"), `${batch}.csv`, JSON.parse(exportJson).csv, "text/csv");
      this.message = `Saved the exact CSV in Salesforce Files and requested its download. Import it manually in Jira. Step 2: import Jira's epic results CSV here, or open each epic and confirm its real Jira key, before exporting children.${warnings.length ? "\n" + warnings.join("\n") : ""}`;
      if (this.exporting.phase === "snapshot") this.message = "Exact raw Jira snapshot saved in Salesforce Files; download requested. This archive is not a Jira creation import.";
      this.exporting = null; await this.load();
    });
  }
  async exportRawSnapshot() {
    if (this.busy || !this.requireSavedEditor()) return;
    if (this.exporting) { this.error = "Finish or save and close the current export first."; return; }
    const t = this.selected, result = rawExportCSV([t]);
    this.exporting = { phase: "snapshot", tickets: [t], count: 1, remaining: 0, blocked: [], pending: {
      batch: `${t.jiraKey || t.atlasId}-snapshot`, warnings: [],
      exportJson: JSON.stringify({ phase: "snapshot", csv: result.csv, versions: { [t.id]: t.version } })
    } };
    this.selected = null;
    await this.downloadExport();
  }

  async importFile(event) {
    const file = event.target.files?.[0]; event.target.value = "";
    if (!file) return;
    await this.guard(async () => {
      if (this.importing) throw Error("Save and close the current import review before choosing another CSV. The previous review has been kept.");
      if (!this.requireSavedEditor()) return;
      if (file.size > 20 * 1024 * 1024) throw Error("Jira CSV exceeds the 20 MiB review limit. No rows were imported; split the Jira export into smaller scopes.");
      const csv = await file.text(), parsed = parseCSV(csv, this.settings?.mapping?.delimiter);
      const { rows, skipped } = importRows(parsed, { people: this.people, mapping: this.settings?.mapping });
      this.importing = { name: file.name || "Jira CSV", csv, rows: reviewImportRows(rows, this.tickets, this.people), skipped, next: 0, manifestId: null,
        totals: { matchedByKey: 0, matchedDrafts: 0, created: 0, stale: 0 } };
      this.importOffset = 0;
      await this.preserveImport();
      this.message = `Review ${rows.length} Jira rows before any ticket mutation. Original CSV and review saved privately in Library & recovery. ${skipped.join(" ")}`;
    });
  }
  get importReviewRows() {
    return (this.importing?.rows || []).slice(this.importOffset, this.importOffset + IMPORT_CHUNK).map((r) => ({ ...r,
      matchOptions: [{ label: "Choose…", value: "" }, { label: "Create new record", value: "new" }, ...r.candidates.map((t) => ({ label: `${t.atlasId} · ${t.summary}`, value: t.id }))],
      identityOptions: [{ label: "Choose…", value: "" }, { label: "Keep current; flag unresolved", value: "keep" }, { label: "Explicitly unassigned", value: "unassigned" },
        ...this.people.map((p) => ({ label: p.name, value: p.id }))],
      assignment: r.assigneeResolution === "person" ? r.assigneeId : r.assigneeResolution,
    }));
  }
  handleImportChoice(event) {
    if (this.importLocked) return;
    const { key, field } = event.target.dataset, value = event.detail.value;
    this.importing = { ...this.importing, source: null, rows: this.importing.rows.map((r) => {
      if (r.key !== key) return r;
      if (field === "resolution") return { ...r, resolution: value, expectedVersion: r.candidates.find((c) => c.id === value)?.version };
      return { ...r, assigneeResolution: ["", "keep", "unassigned"].includes(value) ? value : "person", assigneeId: ["", "keep", "unassigned"].includes(value) ? "" : value };
    }) };
    this.scheduleRecovery();
  }
  cancelImport() {
    return this.guard(async () => {
      await this.preserveImport();
      if (this.importing.manifestId) await this.preserveImportProgress();
      this.importing = null;
      this.message = "Review saved privately in Library & recovery. Closing it did not undo any committed chunks.";
    });
  }
  async confirmImport() {
    if (!this.requireSavedEditor()) return;
    await this.guard(async () => {
      const review = this.importing;
      if (review.rows.some((r) => (r.needsMatch && !r.resolution) || (r.needsAssignee && !r.assigneeResolution))) throw new Error("Resolve every ambiguous draft and unknown assignee first. No new chunk was applied.");
      const selected = review.rows.map((r) => r.resolution).filter((r) => r && r !== "key" && r !== "new");
      if (new Set(selected).size !== selected.length) throw new Error("Two Jira keys selected the same draft. Resolve this before importing.");
      if (!review.manifestId) {
        review.manifestId = await beginImport({ keysJson: JSON.stringify(review.rows.map((r) => r.key)) });
        review.source = null;
      }
      await this.preserveImport();
      this.addReceipt(review.manifestId, "Import key preflight manifest");
      for (let i = review.next; i < review.rows.length; i += IMPORT_CHUNK) {
        if (!this.connected) throw Error("Import paused after leaving Tickets. Reopen the saved review to resume; committed chunks are retained.");
        const rows = review.rows.slice(i, i + IMPORT_CHUNK).map(({ candidates, needsMatch, needsAssignee, ...r }) => r);
        let result;
        try { result = JSON.parse(await importJira({ rowsJson: JSON.stringify({ rows, manifestId: review.manifestId, chunk: i / IMPORT_CHUNK }) })); }
        catch (e) { throw new Error(`Import stopped after ${review.next} of ${review.rows.length} rows. Completed chunks remain committed; receipt links below. Retry resumes at this chunk. ${errorMessage(e)}`); }
        this.addReceipt(result.receiptId, `Import chunk ${i / IMPORT_CHUNK + 1} ${result.applied === false ? "failure" : "receipt"}`);
        if (result.applied === false) throw new Error(`Import stopped after ${review.next} of ${review.rows.length} rows. Completed chunks remain committed. ${result.error}`);
        for (const key of Object.keys(review.totals)) review.totals[key] += result[key] || 0;
        review.next = i + rows.length;
        this.cacheRecovery();
        if (review.next < review.rows.length) await this.preserveImportProgress();
      }
      // Also retry a lost final checkpoint response before clearing the in-memory review.
      await this.preserveImportProgress();
      const t = review.totals;
      this.message = `Read ${review.rows.length} Jira issue(s): ${t.matchedByKey} updated, ${t.matchedDrafts} draft(s) linked, ${t.created} new. ${t.stale} stale row(s) skipped; newer Salesforce ticket values were kept. ${review.skipped.join(" ")}`;
      this.importing = null; await this.load();
    });
  }

  /** The library has already previewed, confirmed and retained the original backup. */
  @api async importLegacy(workspace) {
    this.busy = true; this.error = null;
    const receipts = [];
    try {
      const chunks = legacyChunks(workspace);
      for (let index = 0; index < chunks.length; index++) {
        const result = JSON.parse(await migrateLegacy({ workspaceJson: JSON.stringify(chunks[index]) }));
        receipts.push(result);
        this.addReceipt(result.receiptId, `Legacy ${result.phase} chunk ${index + 1}`);
        this.addReceipt(result.legacyFileId, `Preserved legacy ticket JSON chunk ${index + 1}`);
      }
      await this.load();
      this.message = `Legacy migration completed in ${chunks.length} bounded chunks. Unknown identities and unresolved parents are flagged on tickets; nothing was deleted.`;
      return { receipts, complete: true };
    } catch (e) {
      this.error = `Legacy migration stopped after ${receipts.length} chunks. Retry is idempotent; completed records remain. ${errorMessage(e)}`;
      return { receipts, complete: false, error: this.error };
    } finally { this.busy = false; }
  }
  dismissMessage() { this.message = null; }
}
