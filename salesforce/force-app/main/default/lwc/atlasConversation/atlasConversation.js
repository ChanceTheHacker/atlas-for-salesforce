import { LightningElement, api } from "lwc";
import { loadScript } from "lightning/platformResourceLoader";
import FILES from "@salesforce/resourceUrl/Atlas_Files";
import getConversation from "@salesforce/apex/Atlas_Data.getConversation";
import getMessage from "@salesforce/apex/Atlas_Data.getMessage";
import saveConversation from "@salesforce/apex/Atlas_Data.saveConversation";
import addMessage from "@salesforce/apex/Atlas_Data.addMessage";
import appendMessages from "@salesforce/apex/Atlas_Data.appendMessages";
import saveFile from "@salesforce/apex/Atlas_Data.saveFile";
import getState from "@salesforce/apex/Atlas_Data.getState";
import saveState from "@salesforce/apex/Atlas_Data.saveState";
import messagePage from "@salesforce/apex/Atlas_Data.messagePage";
import confirmAlias from "@salesforce/apex/Atlas_Data.confirmAlias";
import lookupIdentity from "@salesforce/apex/Atlas_Identity.lookup";
import prepareAssignments from "@salesforce/apex/Atlas_Assignments.prepare";
import decideAssignments from "@salesforce/apex/Atlas_Assignments.decide";
import listEntries from "@salesforce/apex/Atlas_Library.listEntries";
import {readLibrary, libraryData} from "c/atlasStorage";
import run from "@salesforce/apex/Atlas_Research.run";
import retrieveStatus from "@salesforce/apex/Atlas_Research.retrieveStatus";
import startBackup from "@salesforce/apex/Atlas_Changes.startBackup";
import backupStatus from "@salesforce/apex/Atlas_Changes.backupStatus";
import propose from "@salesforce/apex/Atlas_Changes.propose";
import getChange from "@salesforce/apex/Atlas_Changes.getChange";
import decide from "@salesforce/apex/Atlas_Changes.decideConfirmed";
import deployStatus from "@salesforce/apex/Atlas_Changes.deployStatus";
import applyBatch from "@salesforce/apex/Atlas_Tickets.applyBatch";
import prepareBatch from "@salesforce/apex/Atlas_Tickets.prepareBatch";
import prepareJiraWrite from "@salesforce/apex/Atlas_JiraWrites.prepareWrite";
import listJiraWrites from "@salesforce/apex/Atlas_JiraWrites.listWrites";
import getJiraWrite from "@salesforce/apex/Atlas_JiraWrites.getWrite";
import jiraCapabilities from "@salesforce/apex/Atlas_Jira.capabilities";
import {
  MAX_REQUESTS,
  UAT_BOUNDARY,
  checkUatPlan,
  validateUatMessageType,
  uatPlanToArtifact,
  uatRepairPrompts,
  uatFailureReport,
  uatIntakeText,
  LIMIT_REMINDER,
  MESSAGE_TYPES,
  intakeQuestions,
  intakeAliases,
  OPS,
  backupReply,
  checkRequests,
  checkTicketBatch,
  checkJiraWrite,
  checkSupportTicketBugDraft,
  checkSupportTicketReport,
  formatSupportTicketReport,
  checkSupportTicketJiraWrite,
  isSupportTicketCredentialVerificationFailure,
  supportTicketBugOperationId,
  supportTicketBugReviewOperationId,
  validateSupportTicketMessageType,
  jiraReviewManager,
  jiraWriteReply,
  correctionReply,
  decisionReply,
  deployReply,
  downloadFile,
  errorMessage,
  errorText,
  filesReply,
  notSavedReply,
  parseAgentJSON,
  requestReply,
  resultText,
  rulesReminder,
  splitReply,
  cachedResearch,
  invalidateResearch,
  researchScope,
  historyQueue,
  pollDelay,
} from "c/atlasLib";

const PARALLEL = 4;
// eslint-disable-next-line @lwc/lwc/no-async-operation
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// The history list is rebuilt when its messages change, not on every render.
const historyRows = new WeakMap();

const LEGACY_LIMIT_REMINDERS = [
  "REMINDER: each response must be at most 14,000 characters. Split larger replies into separate responses.",
  'REMINDER: send Atlas JSON in a fenced json code block; keep prose outside. Serialize and validate it; preserve exact find text. For source edits, copy find from the latest backup/retrieve text for that file, never from memory. If missing, request it with "resend":true and wait before editing. Each response must be at most 14,000 characters including escaping, fences and prose. For longer JSON, use separately serialized atlas-response-part messages, each in its own fenced json block and separate response.',
];
function withoutKnownLimitFooter(value) {
  for (const footer of [LIMIT_REMINDER, ...LEGACY_LIMIT_REMINDERS]) {
    if (!value.endsWith(footer)) continue;
    let end = value.length - footer.length;
    if (end && value[end - 1] !== "\n") continue;
    while (end && value[end - 1] === "\n") end--;
    return value.slice(0, end);
  }
  return value;
}

const FILE_ICONS = { docx: "doctype:word", xlsx: "doctype:excel", pptx: "doctype:ppt", csv: "doctype:csv", txt: "doctype:txt", pdf: "doctype:pdf", html: "doctype:html" };
const changeStatusPill = (status = "") => /deployed|restored|approved/i.test(status) ? "atlas-pill_success"
  : /fail|reject|error/i.test(status) ? "atlas-pill_danger" : /review|pending|progress|backing/i.test(status) ? "atlas-pill_warning" : "";

export default class AtlasConversation extends LightningElement {
  @api conversationId;
  @api boot;
  @api settings;
  convo;
  outgoing;
  paste = "";
  busy = false;
  progress = "";
  problem;
  banner;
  review;
  ticketReview;
  ticketReport = null;
  uatPlan = null;
  uatResults = {testIds: "", expected: "", actual: "", evidence: ""};
  get isUat() { return this.convo?.mode === "uat"; }
  get uatSummary() { return this.uatPlan ? `${this.uatPlan.tests.length} tests. ${this.uatPlan.summary}` : ""; }
  get uatPlanProvenance() {
    return this.uatPlan && this.uatPlan.requestId !== this.conversationId
      ? `This saved plan was recovered from conversation ${this.uatPlan.requestId}. The document retains that original identifier. You are now in conversation ${this.conversationId}; new agent replies must use this current identifier. Recheck the original environment, versions and evidence before executing an older plan.` : "";
  }
  get uatIntake() { return this.isUat ? uatIntakeText(this.convo) : ""; }
  get repairPrompts() { return this.uatPlan ? uatRepairPrompts(this.uatPlan) : []; }
  assertNotUat() { if (this.isUat) throw Error("UAT cannot change Salesforce, execute tests, assign records or change Jira/local tickets. Use a separate Source or Task conversation."); }
  handleUatResult(event) {
    this.uatResults = {...this.uatResults, [event.target.name]: event.detail.value ?? event.target.value};
    this.scheduleDraft();
  }
  async sendUatResults() {
    await this.guard(async () => {
      if (!this.isUat) throw Error("Test results belong in a UAT conversation.");
      await this.send("uat-results", uatFailureReport(this.uatResults, this.conversationId) + "\n" + LIMIT_REMINDER);
      this.banner = {text: "Your test results are saved in this conversation. Copy the message to the agent for read-only investigation; no test or repair was executed."};
    });
  }
  ticketNote = "";
  fileReview;
  artifactsJson;
  previewHtml;
  showHistory = false;
  showRequest = false;
  watching = new Set();
  questions = [];
  identities = [];
  assignmentReview;
  assignmentNote = "";
  assignmentDecision;
  refreshRequest;
  jiraWrites = [];
  // File path → {hash, at} for text the agent already has; see filesText.
  sentFiles = {};
  draftRevision = 0;
  draftStatus = "";
  draftTimer;
  draftQueue = Promise.resolve();
  savedDraftJson;
  draftLoaded = false;
  loadGeneration = 0;
  localRecovery;
  connected = true;
  deferMessages = false;
  historyStatus = "";
  historyAtRisk = false;
  outbox;
  unsubscribeHistory;
  lastResearch;
  bypassCache = false;

  connectedCallback() {
    this.connected = true;
    this.connectHistory();
    this.load(true);
  }

  connectHistory() {
    if (this.outbox) return;
    const conversationId = this.conversationId, scope = researchScope(this.boot);
    this.outbox = historyQueue(scope && conversationId ? `atlas-history:${scope}:${conversationId}` : null,
      async (messages) => JSON.parse(await appendMessages({conversationId, messagesJson: JSON.stringify(messages)})));
    this.unsubscribeHistory = this.outbox.subscribe(({pending, problem, rows}) => {
      if (!this.connected) return;
      this.historyStatus = problem || (pending ? `Saving ${pending} history message(s) in the background…` : "History saved in Salesforce.");
      this.historyAtRisk = !!problem && pending > 0;
      if (this.convo && rows.length) {
        const messages = new Map(this.convo.messages.map((m) => [m.recordId, m]));
        for (const row of rows) messages.set(row.recordId, row);
        this.convo = {...this.convo, messages: [...messages.values()].sort((a, b) => String(a.created).localeCompare(String(b.created)) || String(a.recordId).localeCompare(String(b.recordId)))};
      }
      this.syncOutgoing();
    });
  }
  saveHistory() { this.outbox?.flush().catch(() => {}); }
  downloadHistory() {
    downloadFile(this.template.querySelector("a.atlas-download"), "Atlas-unsaved-history.json", JSON.stringify(this.outbox?.pending || [], null, 2), "application/json");
  }
  clearResearchCache() {
    invalidateResearch(researchScope(this.boot));
    this.banner = {text: "Research cache cleared. The next request reads Salesforce again."};
  }
  async refreshResearch() {
    if (!this.lastResearch) return;
    await this.guard(async () => {
      this.deferMessages = true;
      try { await this.runRequests({...this.lastResearch, fresh: true}); }
      finally { this.deferMessages = false; }
    });
  }

  disconnectedCallback() {
    if (this.draftLoaded) this.cacheDraft();
    this.connected = false;
    this.unsubscribeHistory?.();
    this.outbox = null;
    this.loadGeneration++;
    clearTimeout(this.draftTimer);
    if (this.draftLoaded) this.persistDraft().catch(() => {});
  }

  get draftKey() {
    return `atlas-draft:${this.boot?.org?.id}:${this.boot?.user?.id}:${this.conversationId}`;
  }

  draftData() {
    return { paste: this.paste, uatResults: this.uatResults, ticketReview: this.ticketReview || null, ticketNote: this.ticketNote,
      questions: this.questions, identities: this.identities, assignmentReview: this.assignmentReview || null,
      assignmentNote: this.assignmentNote, assignmentDecision: this.assignmentDecision || null, refreshRequest: this.refreshRequest || null, sentFiles: this.sentFiles };
  }

  applyDraft(data = {}) {
    this.paste = data.paste || "";
    this.ticketReview = data.ticketReview || null;
    this.ticketNote = data.ticketNote || "";
    this.questions = data.questions || [];
    this.identities = data.identities || [];
    this.assignmentReview = data.assignmentReview || null;
    this.assignmentNote = data.assignmentNote || "";
    this.assignmentDecision = data.assignmentDecision || null;
    this.refreshRequest = data.refreshRequest || null;
    this.sentFiles = data.sentFiles || {};
    this.uatResults = {testIds: "", expected: "", actual: "", evidence: "", ...(data.uatResults || {})};
    // Recovery data must never reopen write approval controls in a read-only mode.
    if (this.isUat) {
      this.ticketReview = null; this.assignmentReview = null; this.assignmentDecision = null;
      this.identities = []; this.refreshRequest = null; this.review = null; this.jiraWrites = [];
    }
  }

  /** Sends a reply built from files, and remembers them only once the reply is saved. */
  async sendWithFiles(kind, build) {
    const sent = {...this.sentFiles};
    await this.send(kind, build(sent));
    this.sentFiles = sent;
    this.scheduleDraft();
  }

  cacheDraft() {
    if (!this.connected) return;
    try { sessionStorage.setItem(this.draftKey, JSON.stringify({ revision: this.draftRevision, data: this.draftData() })); }
    catch { this.draftStatus = "Browser draft recovery is unavailable; save or download the draft before leaving."; }
  }

  scheduleDraft() {
    if (!this.draftLoaded) return;
    this.cacheDraft();
    clearTimeout(this.draftTimer);
    this.draftStatus = "Draft save pending…";
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.draftTimer = setTimeout(() => this.persistDraft().catch(() => {}), 1000);
  }

  persistDraft() {
    if (!this.draftLoaded) return Promise.resolve();
    clearTimeout(this.draftTimer);
    const stateJson = JSON.stringify(this.draftData());
    const conversationId = this.conversationId;
    const work = this.draftQueue.then(async () => {
      if (stateJson !== this.savedDraftJson) {
        this.draftRevision = await saveState({ conversationId, expectedRevision: this.draftRevision, stateJson });
        this.savedDraftJson = stateJson;
      }
      // A detached panel may finish its durable save, but must not erase a newer panel's recovery.
      if (this.connected && stateJson === JSON.stringify(this.draftData())) {
        this.draftStatus = "Draft saved in Salesforce.";
        try { sessionStorage.removeItem(this.draftKey); } catch { /* Salesforce copy is durable. */ }
      }
    });
    this.draftQueue = work.catch((e) => {
      this.cacheDraft();
      this.draftStatus = "Draft NOT saved: " + errorMessage(e);
    });
    return work;
  }

  saveDraft() { this.persistDraft().catch(() => {}); }
  recoverLocal() { this.applyDraft(this.localRecovery.data); this.localRecovery = null; this.cacheDraft(); this.draftStatus = "Recovered locally. Review it, then save the draft."; }
  downloadDraft() {
    downloadFile(this.template.querySelector("a.atlas-download"), "Atlas-draft.json", JSON.stringify(this.draftData(), null, 2), "application/json");
  }

  get hasQuestions() { return this.questions.length > 0; }
  get hasJiraWrites() { return this.jiraWrites.length > 0; }
  get ticketUpdateLabel() {
    return this.settings?.jira?.externalCredential?.trim()
      ? "Updates staged for separate Jira review" : "Updates to copy into Jira later";
  }
  get hasIdentities() { return this.identities.length > 0; }
  get identityOptions() {
    return [{label: "Choose a confirmed person", value: ""}, ...(this.boot.people || []).filter((p) => p.active !== false && p.jiraId)
      .map((p) => ({label: `${p.name} (${p.jiraId})`, value: p.id}))];
  }
  handleAnswer(event) {
    this.questions = this.questions.map((q) => q.id === event.target.dataset.id ? {...q, answer: event.detail.value} : q);
    this.scheduleDraft();
  }
  handleIdentity(event) {
    this.identities = this.identities.map((a) => a.alias === event.target.dataset.alias ? {...a, personId: event.detail.value} : a);
    this.scheduleDraft();
  }
  async sendAnswers() {
    await this.guard(async () => {
      if (this.questions.some((q) => !q.answer.trim())) throw Error("Answer each question, or write that it is not yet decided.");
      await this.send("answers", JSON.stringify({type: "atlas-answers", requestId: this.conversationId, answers: this.questions}, null, 2) + "\n" + LIMIT_REMINDER);
      this.banner = {text: "Answers saved. Copy them back to the agent; they remain here for reference."};
    });
  }
  async sendIdentities() {
    await this.guard(async () => {
      this.assertNotUat();
      if (this.identities.some((a) => !a.personId)) throw Error("Select each person. Add missing people in Team & Jira first; do not guess their Jira ID.");
      const result = [];
      for (const a of this.identities) {
        const person = JSON.parse(await lookupIdentity({term: a.personId})).resolved;
        if (!person || person.personId !== a.personId || !person.jiraId) throw Error("This identity changed or is ambiguous. Review Team & Jira before confirming.");
        await this.orgWrite(() => confirmAlias({personId: a.personId, alias: a.alias}));
        result.push({alias: a.alias, userId: person.userId, jiraId: person.jiraId, salesforceUserId: person.userId,
          personId: person.personId, name: person.name, email: person.email, aliases: [...new Set([...(person.aliases || []), a.alias])]});
      }
      await this.send("identities", JSON.stringify({type: "atlas-users-result", requestId: this.conversationId, users: result}, null, 2) + "\n" + LIMIT_REMINDER);
      this.identities = [];
      this.dispatchEvent(new CustomEvent("changed"));
    });
  }

  async olderMessages() {
    await this.guard(async () => {
      const page = JSON.parse(await messagePage({conversationId: this.conversationId, beforeId: this.convo.messageCursor}));
      this.convo = {...this.convo, messages: [...page.messages, ...this.convo.messages], messageCursor: page.cursor};
    });
  }

  async load(first) {
    const generation = ++this.loadGeneration;
    const current = () => this.connected && generation === this.loadGeneration;
    if (first) this.draftLoaded = false;
    try {
      const [raw, state, jiraWrites] = await Promise.all([
        getConversation({conversationId: this.conversationId}),
        first ? getState({conversationId: this.conversationId}) : Promise.resolve(null),
        listJiraWrites({conversationId: this.conversationId}),
      ]);
      if (!current()) return;
      const convo = JSON.parse(raw);
      this.convo = convo;
      this.jiraWrites = this.isUat ? [] : JSON.parse(jiraWrites);
      if (first) {
        const saved = JSON.parse(state);
        this.draftRevision = saved.revision;
        this.applyDraft(saved.data);
        this.savedDraftJson = JSON.stringify(this.draftData());
        try {
          const local = JSON.parse(sessionStorage.getItem(this.draftKey) || "null");
          if (local && JSON.stringify(local.data) !== JSON.stringify(this.draftData())) this.localRecovery = local;
        } catch { /* A corrupt browser recovery copy must not replace Salesforce state. */ }
        const last = [...convo.messages].reverse().find((m) => m.direction === "To Agent");
        const files = this.isUat ? await this.latestUatPlan(convo, current)
          : [...convo.messages].reverse().find((m) => m.direction === "From Agent" && m.kind === "atlas-files");
        const ticketReportMessage = convo.mode === "support-tickets"
          ? [...convo.messages].reverse().find((m) => m.direction === "From Agent" && m.kind === "atlas-support-ticket-report")
          : null;
        const proposed = this.isUat ? null : convo.changes.find((c) => c.status === "Proposed");
        const [body, fileBody, review, ticketReportBody] = await Promise.all([
          last ? this.fullMessage(last) : null,
          files ? this.fullMessage(files) : null,
          proposed ? getChange({changeId: proposed.id}) : null,
          ticketReportMessage ? this.fullMessage(ticketReportMessage) : null,
        ]);
        if (!current()) return;
        if (last) this.showOutgoing(last.kind, body, "saved");
        if (review) this.review = JSON.parse(review);
        if (ticketReportBody) {
          try {
            const report = checkSupportTicketReport(parseAgentJSON(ticketReportBody), this.conversationId);
            this.ticketReport = {...report, text: formatSupportTicketReport(report, this.boot.org)};
          } catch { this.ticketReport = null; }
        }
        if (files) await (this.isUat ? this.restoreUatHistory(files, fileBody, current) : this.listFiles(parseAgentJSON(fileBody), current)).catch((e) => {
          if (this.isUat && current()) this.problem = {text: "The saved UAT plan could not be restored: " + errorMessage(e), canSend: true};
        });
        if (!current()) return;
        const unsaved = [...(this.outbox?.pending || [])].reverse().find((m) => m.direction === "To Agent");
        if (unsaved) this.showOutgoing(unsaved.kind, unsaved.body, "queued");
        this.saveHistory();
        this.draftLoaded = true;
        for (const c of this.isUat ? [] : this.convo.changes)
          if (c.status === "Deploying" || c.status === "Restoring")
            this.finishDeploy(c.id).catch((e) => (this.problem = { text: errorMessage(e) }));
      }
    } catch (e) {
      if (this.connected && generation === this.loadGeneration) this.problem = { text: errorMessage(e) };
    }
  }

  async latestUatPlan(convo, current) {
    let messages = convo.messages, cursor = convo.messageCursor;
    const visited = new Set();
    for (;;) {
      const found = [...messages].reverse().find((m) => m.direction === "From Agent" && m.kind === "atlas-uat-plan");
      if (found) return found;
      if (!cursor || !current()) return null;
      if (visited.has(cursor)) throw Error("History paging did not advance while restoring the UAT plan. Load older messages to recover it.");
      visited.add(cursor);
      const page = JSON.parse(await messagePage({conversationId: this.conversationId, beforeId: cursor}));
      messages = page.messages; cursor = page.cursor;
    }
  }

  async openUatPlan(event) {
    await this.guard(async () => {
      const message = this.convo.messages.find((m) => m.id === event.currentTarget.dataset.id);
      if (!this.isUat || message?.kind !== "atlas-uat-plan") throw Error("Choose a UAT plan from this conversation's history.");
      await this.restoreUatHistory(message, await this.fullMessage(message));
    });
  }

  fullMessage(message) {
    return message.hasFullBody ? getMessage({ messageId: message.recordId }) : Promise.resolve(message.body);
  }

  async showHistoryMessage(event) {
    const id = event.currentTarget.dataset.id;
    await this.guard(async () => {
      const message = this.convo.messages.find((m) => m.id === id);
      const body = await this.fullMessage(message);
      this.convo = { ...this.convo, messages: this.convo.messages.map((m) => m.id === id ? { ...m, body, hasFullBody: false } : m) };
    });
  }

  // ---- display

  get ready() {
    return !!this.convo && this.draftLoaded;
  }
  get modeLabel() {
    return this.isUat ? "UAT" : this.convo.mode === "support-tickets" ? "Support Tickets" : this.convo.mode;
  }
  get closeLabel() {
    return this.convo.status === "Closed" ? "Reopen" : "Close";
  }
  get closeIcon() {
    return this.convo.status === "Closed" ? "utility:undo" : "utility:check";
  }
  get modePill() {
    return "atlas-pill " + ({ Source: "atlas-pill_accent", Task: "atlas-pill_epic", Files: "atlas-pill_success", "support-tickets": "atlas-pill_warning", uat: "atlas-pill_success" }[this.convo.mode] || "");
  }
  get statusPill() {
    return this.convo.status === "Closed" ? "atlas-pill" : "atlas-pill atlas-pill_success";
  }
  get hasRelated() {
    return this.hasChanges || this.hasTickets;
  }
  get changeRows() {
    return this.convo.changes.map((c) => ({ ...c, statusClass: "atlas-pill " + changeStatusPill(c.status) }));
  }
  get historyIcon() {
    return this.showHistory ? "utility:chevronup" : "utility:chevrondown";
  }
  get historyNeedsRetry() {
    return !!this.historyStatus && this.historyStatus !== "History saved in Salesforce.";
  }
  get historyClass() {
    if (this.historyStatus === "History saved in Salesforce.") return "atlas-history-status atlas-history-status_saved";
    return this.historyStatus.startsWith("Saving ") ? "atlas-history-status" : "atlas-history-status atlas-history-status_problem";
  }
  handleMenu(event) {
    const action = event.detail.value;
    if (action === "remind") this.remindRules();
    else if (action === "download") this.downloadDraft();
    else if (action === "refresh") this.refreshResearch();
    else if (action === "clear") this.clearResearchCache();
  }
  get hasTickets() {
    return this.convo.tickets?.length > 0;
  }
  get hasChanges() {
    return this.convo.changes?.length > 0;
  }
  get historyLabel() {
    return this.showHistory ? "Hide earlier messages" : `Show earlier messages (${this.convo.messages.length})`;
  }
  get requestLabel() {
    return this.showRequest ? "Hide my request" : "Show my request";
  }
  get history() {
    const messages = this.convo.messages;
    if (!historyRows.has(messages)) historyRows.set(messages, [...messages].reverse().map((m) => ({
      ...m,
      isUatPlan: m.kind === "atlas-uat-plan" && m.direction === "From Agent",
      who: m.direction === "To Agent" ? "Atlas → agent" : "Agent → Atlas",
      when: new Date(m.created).toLocaleString(),
      className: "atlas-event " + (m.direction === "To Agent" ? "atlas-to" : "atlas-from"),
    })));
    return historyRows.get(messages);
  }
  get pasteDisabled() {
    return this.busy || !this.paste.trim();
  }
  get partsInfo() {
    const n = this.outgoing?.parts.length || 0;
    return n > 1
      ? `This message is in ${n} parts because it is longer than your ${this.settings.mine.replyLimit.toLocaleString()}-character limit. Send each part as its own chat message, in order.`
      : "";
  }

  /**
   * saved: in Salesforce. saving: its write is in flight. queued: in the history
   * queue, saved once it leaves it. failed: shown here only.
   */
  uatOutgoing(text) {
    if (!this.isUat) return text;
    const note = `UAT REQUEST ID: ${this.conversationId}\n${UAT_BOUNDARY}`;
    return text.includes(note) ? text : `${text.trimEnd()}\n\n${note}`;
  }
  showOutgoing(kind, text, state) {
    const original = text;
    // Only exact, known protocol footers are removed. Diagnostic text is evidence.
    const stripReminder = (value) => {
      let next = withoutKnownLimitFooter(value);
      while (next !== value) {
        value = next;
        next = withoutKnownLimitFooter(value);
      }
      return value;
    };
    const uatSuffix = `\n\nUAT REQUEST ID: ${this.conversationId}\n${UAT_BOUNDARY}`;
    text = stripReminder(text);
    if (this.isUat && text.endsWith(uatSuffix))
      text = stripReminder(text.slice(0, -uatSuffix.length)) + uatSuffix;
    text = this.uatOutgoing(text);
    if (this.convo?.mode === "support-tickets" && this.conversationId && !String(text).includes("SUPPORT TICKETS REQUEST ID:"))
      text = `${text.trimEnd()}\n\nSUPPORT TICKETS REQUEST ID: ${this.conversationId}. Copy this exact value into the report or Bug proposal.`;
    text = `${text}\n\n${LIMIT_REMINDER}`;
    const parts = splitReply(text, this.settings.mine.replyLimit);
    this.outgoing = {
      kind,
      original,
      text,
      state,
      truncated: text.includes("[Atlas stored only the first part of this message"),
      parts: parts.map((p, i) => ({
        key: i,
        text: p,
        label: parts.length > 1 ? `Copy part ${i + 1} of ${parts.length}` : "Copy message for the agent",
        size: `${p.length.toLocaleString()} characters`,
      })),
    };
  }

  markOutgoing(text, state) {
    if ((this.outgoing?.text === text || this.outgoing?.original === text) && this.outgoing.state !== state) this.outgoing = {...this.outgoing, state};
  }
  /** A queued message is saved only once no pending history entry still holds it. */
  syncOutgoing() {
    const text = this.outgoing?.original;
    if (this.outgoing?.state === "queued" && !(this.outbox?.pending || []).some((m) => m.direction === "To Agent" && m.body === text)) this.markOutgoing(text, "saved");
  }
  get outgoingSave() {
    const state = this.outgoing?.state;
    if (state === "saved") return {text: "Saved in this conversation's history in Salesforce.", className: "atlas-history-status atlas-history-status_saved"};
    if (state === "failed") return {text: "NOT saved in Salesforce. It is shown only here, so it is missing from the conversation history.", className: "atlas-history-status atlas-history-status_problem"};
    if (state === "queued" && this.historyAtRisk)
      return {text: "Not saved in Salesforce yet. See the history status below the reply box.", className: "atlas-history-status atlas-history-status_problem"};
    return {text: "Shown before Salesforce has saved it. Saving it to the conversation history…", className: "atlas-history-status"};
  }
  /** Shows a reply for the agent and queues it for history. */
  queueOutgoing(kind, text) {
    text = this.uatOutgoing(text);
    // Connect first: the subscription's first report must not mark this message saved.
    this.connectHistory();
    this.showOutgoing(kind, text, "queued");
    try { return this.outbox.enqueue({direction: "To Agent", kind, body: text}); }
    catch (e) { this.markOutgoing(text, "failed"); throw e; }
  }

  async orgWrite(work) {
    this.assertNotUat();
    invalidateResearch(researchScope(this.boot));
    try { return await work(); }
    finally { invalidateResearch(researchScope(this.boot)); }
  }

  async send(kind, text) {
    text = this.uatOutgoing(text);
    if (this.deferMessages) return this.queueOutgoing(kind, text);
    this.showOutgoing(kind, text, "saving");
    try {
      await this.outbox?.flush();
      await addMessage({ conversationId: this.conversationId, direction: "To Agent", kind, body: text });
    } catch (e) { this.markOutgoing(text, "failed"); throw e; }
    this.markOutgoing(text, "saved");
  }

  // ---- toolbar

  toggleHistory() {
    this.showHistory = !this.showHistory;
  }
  toggleRequest() {
    this.showRequest = !this.showRequest;
  }
  async remindRules() {
    await this.guard(async () => {
      await this.send("reminder", rulesReminder({ conversation: this.convo, boot: this.boot, mine: this.settings.mine, jira: this.settings.jira }));
      // An agent that needed the rules again may have lost earlier files too, so send them in full next time.
      this.sentFiles = {};
      this.scheduleDraft();
    });
  }
  async toggleClosed() {
    await this.guard(async () => {
      await saveConversation({
        // Only the status changes; resending the request would store another copy of a long one.
        conversationJson: JSON.stringify({ id: this.convo.id, status: this.convo.status === "Closed" ? "Open" : "Closed" }),
      });
      await this.load();
      this.dispatchEvent(new CustomEvent("changed"));
    });
  }
  dismissBanner() {
    this.banner = null;
  }
  async sendProblem() {
    const text = this.problem.text;
    this.problem = null;
    await this.guard(() => this.send("correction", correctionReply(text)));
  }

  async guard(work) {
    if (this.busy) return;
    this.busy = true;
    this.problem = null;
    try {
      await work();
    } catch (e) {
      this.problem = { text: errorMessage(e), canSend: true };
    } finally {
      this.progress = "";
      // Business writes explicitly await their recovery checkpoint before submission.
      // Routine draft bookkeeping stays serialized without holding the controls.
      if (this.draftLoaded) {
        this.cacheDraft();
        this.persistDraft().catch(() => {});
      }
      this.busy = false;
    }
  }

  // ---- agent replies

  handlePaste(event) {
    this.paste = event.target.value;
    this.scheduleDraft();
  }

  async processPaste() {
    if (this.busy) return;
    let message, validatedTicketReport;
    this.problem = null;
    try {
      message = parseAgentJSON(this.paste);
      if (message.requestId && message.requestId !== this.conversationId)
        throw Error("This reply belongs to a different conversation. Open that conversation before processing it.");
      if (this.isUat) {
        validateUatMessageType(message);
        if (message.type === "atlas-uat-plan") uatPlanToArtifact(message, this.conversationId);
      } else if (message.type === "atlas-uat-plan") throw Error("Open a UAT conversation before processing a UAT plan.");
      if (this.convo?.mode === "support-tickets") {
        validateSupportTicketMessageType(message);
        if (message.type === "atlas-support-ticket-report")
          validatedTicketReport = checkSupportTicketReport(message, this.conversationId);
        else if (message.type === "atlas-tickets") {
          const checked = checkSupportTicketBugDraft(message, this.conversationId, { people: this.boot.people, projectKey: this.settings.jira.projectKey, jira: this.settings.jira });
          if (checked.errors.length) throw Error(checked.errors.join("\n"));
        } else if (message.type === "atlas-jira-write")
          checkSupportTicketJiraWrite(message, this.conversationId, { people: this.boot.people, jira: this.settings.jira });
      }
    } catch (e) {
      this.problem = { text: e.message, canSend: true };
      return;
    }
    const originalPaste = this.paste;
    const needsCommit = ["atlas-backup", "atlas-change", "atlas-assign", "atlas-tickets", "atlas-jira-write", "atlas-support-ticket-report", "atlas-uat-plan"].includes(message.type);
    await this.guard(async () => {
      this.connectHistory();
      this.deferMessages = !needsCommit;
      try {
        await this.outbox.enqueue({direction: "From Agent", kind: String(message.type || "unknown").slice(0, 40), body: originalPaste});
        if (needsCommit) await this.outbox.flush();
        if (message.type === "atlas-request") await this.runRequests(message);
        else if (message.type === "atlas-backup") await this.backup(message);
        else if (message.type === "atlas-change") await this.proposeChange(message);
        else if (message.type === "atlas-assign") await this.reviewAssignments(message);
        else if (message.type === "atlas-tickets") await this.checkTickets(message);
        else if (message.type === "atlas-support-ticket-report") {
          this.ticketReport = { ...validatedTicketReport, text: formatSupportTicketReport(validatedTicketReport, this.boot.org) };
          if (validatedTicketReport.jiraEscalation) await this.prepareSupportTicketEscalation(validatedTicketReport.jiraEscalation);
          else this.banner = {text: "The support findings are ready. No engineering Bug was proposed; review the evidence and production steps below."};
        }
        else if (message.type === "atlas-uat-plan") {
          await this.listFiles(message);
          await this.send("uat-plan", `UAT Word plan prepared: ${this.uatPlan.title}. ${this.uatPlan.tests.length} tests are ready for the user to review and execute. No tests ran and no outcomes are marked. The user may report failed or blocked tests here with IDs and evidence.\n${LIMIT_REMINDER}`);
          this.banner = {text: "The UAT Word plan is ready to download or save. No tests have been run. Review the environment, evidence and limitations before executing it yourself."};
        }
        else if (message.type === "atlas-files") await this.showFiles(message);
        else if (message.type === "atlas-questions") this.questions = intakeQuestions(message, this.questions);
        else if (message.type === "atlas-users") this.identities = intakeAliases(message, this.boot.people);
        else if (message.type === "atlas-context") await this.readContext(message);
        else if (message.type === "atlas-jira-refresh") await this.requestJiraRefresh(message);
        else if (message.type === "atlas-jira-write") await this.reviewJiraWrite(message);
        else
          await this.send(
            "correction",
            correctionReply(`Unknown message type "${message.type}". Use ${MESSAGE_TYPES.join(", ")}.`),
          );
        if (this.paste === originalPaste) {
          this.paste = "";
          const input = this.template.querySelector("textarea.atlas-paste");
          if (input) input.value = "";
        }
        if (needsCommit) await this.load();
      } catch (error) {
        if (needsCommit) {
          const text = `ATLAS could not complete ${message.type}. Do not assume it succeeded or blindly resubmit an uncertain write.\nExact Salesforce/Atlas error:\n${errorMessage(error)}\n${LIMIT_REMINDER}`;
          // A failed history save must not hide the original operation failure.
          try { await this.queueOutgoing("operation-error", text); } catch { /* The outbox exposes its own recovery warning. */ }
        }
        throw error;
      } finally { this.deferMessages = false; }
    });
  }

  async reviewAssignments(message) {
    this.assertNotUat();
    if (this.assignmentReview) throw Error("Finish the current Case assignment review before replacing it.");
    this.assignmentReview = JSON.parse(await prepareAssignments({conversationId: this.conversationId, assignmentsJson: JSON.stringify(message.cases)}));
    this.assignmentNote = "";
    this.assignmentDecision = null;
  }
  handleAssignmentNote(event) { if (!this.assignmentDecision) { this.assignmentNote = event.detail.value; this.scheduleDraft(); } }
  approveAssignments() { return this.finishAssignments(true); }
  rejectAssignments() { return this.finishAssignments(false); }
  retryAssignments() { return this.finishAssignments(this.assignmentDecision?.approve); }
  async finishAssignments(approve) {
    await this.guard(async () => {
      this.assertNotUat();
      if (!this.assignmentReview) return;
      if (!this.assignmentDecision) this.assignmentDecision = {approve, note: this.assignmentNote,
        reviewJson: JSON.stringify(this.assignmentReview), nonce: `${Date.now()}-${Math.random().toString(36).slice(2)}`};
      // Persist the exact receipt before mutation. An uncertain reply must only retry that decision.
      await this.persistDraft();
      const body = await this.orgWrite(() => decideAssignments({conversationId: this.conversationId, ...this.assignmentDecision}));
      // Apex saves this handoff with the decision.
      this.showOutgoing("case-assignment", body + "\n" + LIMIT_REMINDER, "saved");
      this.assignmentReview = null;
      this.assignmentDecision = null;
      await this.load();
    });
  }

  async readContext(message) {
    this.assertNotUat();
    let result;
    if (!message.libraryId) {
      result = JSON.parse(await listEntries({kind: message.kind || null, search: message.search || "", cursor: message.cursor || null, pageSize: 25}));
    } else {
      await loadScript(this, FILES);
      const row = await readLibrary({recordId: message.libraryId, ...(message.versionId ? {versionId: message.versionId} : {})});
      const lib = window.AtlasFiles;
      // Only document views need the parsed entry; the others read the text. readLibrary already parsed it once.
      const document = row.kind === "document" ? libraryData(row) : null;
      if (row.kind === "document" && message.search) {
        result = lib.searchDocument(document, message.search, message.offset || 0);
      } else {
        const paging = {offset: message.offset ?? 0, maxChars: message.maxChars ?? 20000};
        if (message.view === "source") result = lib.sourceFileContext(row.dataJson, {...message, ...paging});
        else if (message.view === "graph") {
          const graph = lib.sourceGraph(row.dataJson);
          result = lib.contextPage([JSON.stringify({scope: graph.scope, entities: graph.entities.map((e) => ({id:e.id, name:e.name, type:e.type, paths:e.files.map((f) => f.path)})), refs: graph.refs})], paging);
        } else if (message.view === "pack") result = lib.sourcePackContext(row.dataJson, paging);
        else result = row.kind === "document"
          ? lib.libraryDocumentContext(document, message.section ? {section: message.section, start: message.start ?? 1, ...(message.end ? {end: message.end} : {})} : undefined, paging)
          : lib.sourceNotebookContext(row.dataJson, message.path || "", paging);
      }
      result = {...result, libraryId: row.id, revision: row.revision, versionId: row.loadedVersionId || row.versionId, title: row.title, kind: row.kind};
    }
    await this.send("context", JSON.stringify({type: "atlas-context-result", requestId: this.conversationId, result}, null, 2) + "\n" + LIMIT_REMINDER);
  }

  async prepareSupportTicketEscalation(escalation) {
    this.assertNotUat();
    const jira = this.settings.jira;
    const manager = jiraReviewManager(jira, this.boot.people);
    const liveReady = !!jira.externalCredential?.trim() && jira.writeEnabled === true && !!jira.projectKey && manager.ready;
    let credentialFallback = false;
    if (liveReady) {
      const assignee = manager.identityType === "accountId" ? {accountId: manager.jiraId} : {name: manager.jiraId};
      try {
        // Server receipts are authoritative; stale local state must never permit a second proposal.
        const savedWrites = JSON.parse(await listJiraWrites({conversationId: this.conversationId}));
        this.jiraWrites = savedWrites;
        const baseOperationId = supportTicketBugOperationId(this.conversationId, escalation.summary, escalation.description, {
          projectKey: jira.projectKey, identityType: manager.identityType, jiraId: manager.jiraId,
        });
        const operationId = supportTicketBugReviewOperationId(baseOperationId, jira, savedWrites);
        if (!operationId)
          throw Error("The saved Jira receipt does not confirm that the previous review was invalidated without sending. No new Bug review was prepared.");
        await this.reviewJiraWrite({
          type: "atlas-jira-write",
          requestId: this.conversationId,
          operationId,
          operation: "create",
          fields: {
            project: {key: jira.projectKey},
            issuetype: {name: "Bug"},
            summary: escalation.summary,
            description: escalation.description,
            assignee,
            labels: ["atlas-manager-review"],
          },
        });
        return;
      } catch (error) {
        if (error?.supportTicketCredentialVerificationRejected !== true) throw error;
        credentialFallback = true;
      }
    }
    const message = {
      type: "atlas-tickets",
      requestId: this.conversationId,
      tickets: [{
        ref: "ATLBUG",
        issueType: "Bug",
        summary: escalation.summary,
        description: escalation.description,
        assignee: manager.ready ? manager.jiraId : null,
      }],
    };
    await this.checkTickets(message);
    if (this.ticketReview) {
      const credentialNote = credentialFallback
        ? " The live Jira credential could not be verified, so no live proposal was prepared."
        : "";
      this.ticketReview = {
        ...this.ticketReview,
        supportTicketWarning: manager.ready
          ? `This is a local Bug draft assigned to ${manager.name} for review. It is not in Jira yet; saving it only adds it to Atlas for CSV export.${credentialNote}`
          : `This local Bug draft is intentionally unassigned because no confirmed review manager is ready. ${manager.message} Saving it does not create a Jira issue.`,
      };
      this.banner = {text: manager.ready
        ? `A local Bug draft is ready for review and CSV export. It has not been sent to Jira.${credentialNote}`
        : "An unassigned local Bug draft is ready. Fix the review-manager setup before routing it; it has not been sent to Jira."};
    }
  }

  async reviewJiraWrite(message) {
    this.assertNotUat();
    const request = this.convo?.mode === "support-tickets"
      ? checkSupportTicketJiraWrite(message, this.conversationId, {people: this.boot.people, jira: this.settings.jira})
      : checkJiraWrite(message, this.conversationId);
    let prepared;
    try {
      prepared = await prepareJiraWrite({conversationId: this.conversationId, requestJson: JSON.stringify(request)});
    } catch (error) {
      if (this.convo?.mode === "support-tickets" && isSupportTicketCredentialVerificationFailure(error)) {
        const safeFallback = new Error(errorMessage(error));
        safeFallback.supportTicketCredentialVerificationRejected = true;
        throw safeFallback;
      }
      throw error;
    }
    const operation = JSON.parse(prepared);
    this.jiraWrites = [operation, ...this.jiraWrites.filter((row) => row.id !== operation.id)];
    this.banner = {text: "The Jira request is saved for exact review. Pasting a proposal does not approve or send it."};
    await this.send("jira-write", jiraWriteReply(operation, this.conversationId));
  }

  async handleJiraWriteChanged(event) {
    const operation = event.detail.operation;
    if (!operation || !this.connected) return;
    const before = this.jiraWrites.find((row) => row.id === operation.id);
    this.jiraWrites = this.jiraWrites.map((row) => row.id === operation.id ? operation : row);
    invalidateResearch(researchScope(this.boot));
    if (before?.state === operation.state && JSON.stringify(before?.result) === JSON.stringify(operation.result)) return;
    try {
      await this.queueOutgoing("jira-write", jiraWriteReply(operation, this.conversationId));
    } catch (e) {
      this.problem = {text: "The Jira receipt is saved, but its message for the agent could not be queued. Use Send Jira result to agent to recover it. " + errorMessage(e)};
    }
  }

  async sendJiraResult(event) {
    const id = event.currentTarget.dataset.id;
    await this.guard(async () => {
      const operation = JSON.parse(await getJiraWrite({operationId: id}));
      this.jiraWrites = this.jiraWrites.map((row) => row.id === id ? operation : row);
      await this.send("jira-write", jiraWriteReply(operation, this.conversationId));
    });
  }

  async requestJiraRefresh(message) {
    this.assertNotUat();
    const keys = message.keys;
    if (!Array.isArray(keys) || !keys.length || keys.length > 100 || keys.some((k) => !/^[A-Z][A-Z0-9_]*-\d+$/i.test(k)))
      throw Error("Request 1–100 real Jira keys for a scoped refresh.");
    const config = JSON.parse(await jiraCapabilities());
    if (config.connected) {
      if (!config.readEnabled) throw Error("Live Jira Read is disabled in Team & Jira. The Salesforce mirror is not current Jira evidence.");
      await this.runRequests({type: "atlas-request", fresh: true, requests: [{id: "jira-refresh", op: "jira", action: "search",
        jql: `key in (${[...new Set(keys.map((key) => key.toUpperCase()))].map((key) => `"${key}"`).join(", ")}) ORDER BY updated DESC`,
        fields: ["summary", "description", "status", "assignee", "priority", "duedate", "parent", "updated"], maxResults: 50}]});
      this.refreshRequest = null;
      return;
    }
    this.refreshRequest = { keys: [...new Set(keys.map((k) => k.toUpperCase()))], reason: String(message.reason || "Refresh current Jira evidence") };
    this.refreshRequest.jql = `key in (${this.refreshRequest.keys.map((k) => `"${k}"`).join(", ")}) ORDER BY updated DESC`;
  }

  async finishJiraRefresh() {
    await this.guard(async () => {
      await this.runRequests({type: "atlas-request", requests: [{id: "jira-refresh", op: "tickets", keys: this.refreshRequest.keys, description: true, limit: 100}]});
      this.refreshRequest = null;
    });
  }

  async runRequests(message) {
    if (this.isUat) validateUatMessageType(message);
    const { errors, requests } = checkRequests(message);
    if (!requests.length) return this.send("correction", correctionReply(errors));
    const blocks = [], results = [];
    this.lastResearch = message;
    let hits = 0;
    let next = 0,
      done = 0;
    const worker = async () => {
      while (next < requests.length && this.connected) {
        const i = next++;
        const request = requests[i];
        try {
          if (!OPS.includes(request.op)) throw new Error(`Unknown op "${request.op}". Use one of: ${OPS.join(", ")}.`);
          const {result, cache} = await cachedResearch(researchScope(this.boot),
            {...request, fresh: message.fresh === true || request.fresh === true || this.bypassCache}, async () => {
              let result = JSON.parse(await run({requestJson: JSON.stringify(request)}));
              if (request.op === "retrieve") result = await this.waitForRetrieve(result.asyncId);
              return result;
            });
          if (cache.hit) hits++;
          results[i] = {result, cache};
        } catch (e) {
          blocks[i] = errorText(request, errorMessage(e));
        }
        this.progress = `Looked up ${++done} of ${requests.length}…`;
      }
    };
    this.progress = `Looking up ${requests.length} request(s)…`;
    await Promise.all(Array.from({ length: Math.min(PARALLEL, requests.length) }, worker));
    if (!this.connected) throw Error("Research paused after leaving the conversation. Your reply is saved; reopen it to retry.");
    const notRun = message.requests?.length > MAX_REQUESTS
      ? [`=== NOT RUN ===\nOnly the first ${MAX_REQUESTS} requests ran. Send the other ${message.requests.length - MAX_REQUESTS} in your next message.`] : [];
    // Files are compared in request order once every lookup is back.
    await this.sendWithFiles("results", (sent) => requestReply([...requests.map((request, i) => {
      if (blocks[i]) return blocks[i];
      try { return resultText({...request, resend: message.resend === true || request.resend === true}, results[i].result, results[i].cache, sent); }
      catch (e) { return errorText(request, errorMessage(e)); }
    }), ...notRun]));
    this.banner = {text: `${requests.length} research request(s) finished; ${hits} reused a recent result. Live Jira reads are never served from this cache.`};
  }

  async waitForRetrieve(asyncId) {
    // Five minutes; the count also stops it when timers run early.
    const deadline = Date.now() + 300000;
    for (let i = 0; i < 300 && Date.now() < deadline; i++) {
      await sleep(pollDelay(i, 2000));
      const status = JSON.parse(await retrieveStatus({ asyncId }));
      if (status.done) {
        if (!status.files && status.error) throw new Error(status.error);
        return status;
      }
    }
    throw new Error("Salesforce did not finish the retrieve within 5 minutes. Try fewer components.");
  }

  changeId(name) {
    const wanted = String(name || "").trim().toUpperCase();
    const found = this.convo.changes.find((c) => c.name.toUpperCase() === wanted || c.id.toUpperCase() === wanted);
    if (!found)
      throw new Error(
        name
          ? `${name} is not a change in this conversation. Use the change ID from the backup message${this.convo.changes.length ? " (" + this.convo.changes.map((c) => c.name).join(", ") + ")" : ""}.`
          : 'Add "change" with the change ID from the backup message, for example "CHG-00001". If there is no backup yet, send atlas-backup first.',
      );
    return found.id;
  }

  async backup(message) {
    this.assertNotUat();
    if (!Array.isArray(message.components) || !message.components.length)
      return this.send("correction", correctionReply('atlas-backup needs "components": [{"type","name"}, ...].'));
    const started = JSON.parse(
      await startBackup({
        conversationId: this.conversationId,
        changeId: message.change ? this.changeId(message.change) : null,
        summary: message.summary || "",
        componentsJson: JSON.stringify(message.components),
      }),
    );
    let status;
    const deadline = Date.now() + 300000;
    for (let i = 0; i < 300 && Date.now() < deadline && !status?.done; i++) {
      this.progress = `Backing up ${message.components.length} component(s) as ${started.change.name}${status?.status ? " (" + status.status + ")" : ""}…`;
      await sleep(pollDelay(i, 2000));
      status = JSON.parse(await backupStatus({ changeId: started.change.id, asyncId: started.asyncId }));
    }
    if (!status?.done) throw new Error("Salesforce did not finish the backup within 5 minutes. Try fewer components.");
    const change = status.change;
    this.downloadUrl(change.backupUrl);
    this.banner = {
      text: `Backup ${change.name} is saved in Salesforce and its download was requested (${change.found.length} existing component(s)${change.missing.length ? `, ${change.missing.length} new` : ""}). Check that the ZIP arrived and keep it; use the link below if the browser blocked the download.`,
      url: change.backupUrl,
      label: "Download it again",
    };
    await this.sendWithFiles("backup", (sent) => backupReply(change, status.files, true, sent, message.resend === true));
  }

  downloadUrl(url) {
    const link = this.template.querySelector("a.atlas-download");
    link.href = url;
    link.click();
  }

  async proposeChange(message) {
    this.assertNotUat();
    this.review = JSON.parse(await propose({ changeId: this.changeId(message.change), proposalJson: JSON.stringify(message) }));
    this.banner = { text: `The agent proposed ${this.review.name} revision ${this.review.revision}. Review it below, then approve or reject.` };
  }

  async handleDecide(event) {
    const { approve, note, testLevel, activationConfirmed } = event.detail;
    const change = this.review;
    await this.guard(async () => {
      const decided = JSON.parse(await this.orgWrite(() => decide({ changeId: change.id, revision: change.revision, approve, note, testLevel, activationConfirmed })));
      this.review = null;
      if (!approve) {
        this.banner = { text: `${decided.name} was rejected. Your note is in the message to the agent below.` };
        // Apex commits the decision and handoff together, even if this response is lost.
        this.showOutgoing("decision", decisionReply(decided, false, note), "saved");
      } else await this.finishDeploy(decided.id);
      await this.load();
    });
  }

  async finishDeploy(changeId) {
    this.assertNotUat();
    if (this.watching.has(changeId)) return;
    this.watching.add(changeId);
    this.bypassCache = true;
    invalidateResearch(researchScope(this.boot));
    try {
      const deadline = Date.now() + 2400000;
      for (let i = 0; i < 1600 && Date.now() < deadline && this.connected; i++) {
        const status = JSON.parse(await deployStatus({ changeId }));
        const c = status.change;
        const r = status.result || {};
        const parts = [];
        if (Number(r.numberComponentsTotal)) parts.push(`${r.numberComponentsDeployed || 0} of ${r.numberComponentsTotal} components`);
        if (Number(r.numberTestsTotal)) parts.push(`${r.numberTestsCompleted || 0} of ${r.numberTestsTotal} tests`);
        const verb = c.status === "Restoring" ? "Restoring" : "Deploying";
        this.progress = `${verb} ${c.name}: ${r.status || "starting"}${parts.length ? " (" + parts.join(", ") + ")" : ""}…`;
        if (r.resultUnknown) {
          this.banner = {text: `${c.name}: Salesforce returned an unconfirmed outcome. Do not resubmit; refresh this change to check the existing deployment.`};
          const text = status.message || deployReply({...c, result: r});
          await this.queueOutgoing("deploy", text);
          return;
        }
        if (status.done) {
          this.progress = "";
          const restore = c.result?.operation === "restore";
          const ok = c.result?.success === "true";
          this.banner = {
            text: ok
              ? restore
                ? `${c.name} was restored from its backup.`
                : `${c.name} deployed.`
              : c.result?.outcomeUnknown
                ? `${c.name}: submission outcome unknown. Check Salesforce Deployment Status before any retry; the original backup is preserved.`
                : `The ${restore ? "restore" : "deployment"} of ${c.name} failed. Salesforce returned the errors shown in the message below.`,
          };
          // The outcome and the durable agent handoff are saved together by Apex.
          this.showOutgoing("deploy", status.message || deployReply({ ...c, result: status.result || c.result }), "saved");
          return;
        }
        await sleep(pollDelay(i));
      }
      this.banner = { text: "The deployment is still running. Check it later on the Salesforce changes tab." };
    } catch (error) {
      const text = `ATLAS could not check deployment ${changeId}. Its outcome is NOT YET KNOWN. No retry was submitted. Refresh this change to check the existing deployment; do not submit another proposal until its outcome is confirmed.\nExact Salesforce/Atlas error:\n${errorMessage(error)}\n${LIMIT_REMINDER}`;
      try { await this.queueOutgoing("deploy", text); } catch { /* Keep the original polling error and the visible outbox warning. */ }
      throw error;
    } finally {
      this.watching.delete(changeId);
      this.bypassCache = this.watching.size > 0;
      invalidateResearch(researchScope(this.boot));
    }
  }

  async checkTickets(message) {
    this.assertNotUat();
    const supportTicket = this.convo?.mode === "support-tickets";
    let errors, batch, manager;
    if (supportTicket) {
      const checked = checkSupportTicketBugDraft(message, this.conversationId, { people: this.boot.people, projectKey: this.settings.jira.projectKey, jira: this.settings.jira });
      ({errors, batch, manager} = checked);
    } else {
      ({errors, batch} = checkTicketBatch(message, { people: this.boot.people, projectKey: this.settings.jira.projectKey }));
    }
    if (errors.length) {
      this.banner = { text: `The agent's tickets had ${errors.length} problem(s). Nothing was saved; send the correction below.` };
      return this.send("correction", correctionReply(errors));
    }
    const epicNames = new Map(batch.epics.map((e) => [e.ref, e.summary]));
    const row = (t) => {
      const assigneeName = t.assigneeName || this.boot.people?.find((p) => p.id === t.assigneeId)?.name || "";
      return {
        ...t,
        key: t.ref,
        assignee: assigneeName || "nobody",
        due: t.dueDate ? `${t.dueDate}${t.dueDateSource === "suggested" ? " (suggested)" : ""}` : "Not set",
        epic: t.epicRef ? epicNames.get(t.epicRef) : t.epicTicket || t.epicKey || "",
      };
    };
    this.ticketReview = {
      isSupportTicketBug: supportTicket,
      saveLabel: supportTicket ? (manager.ready ? "Save local Bug draft" : "Save unassigned Bug draft") : "Save tickets",
      rejectLabel: supportTicket ? "Ask the agent to revise the Bug" : "Ask the agent to change them",
      supportTicketWarning: supportTicket
        ? manager.ready
          ? `This is a local Bug draft assigned to ${manager.name} for manager review. Saving it does not create a Jira issue.`
          : `This draft is intentionally unassigned because no confirmed review manager is ready. ${manager.message} Saving it does not create a Jira issue.`
        : "",
      items: [...batch.epics.map(row), ...batch.tickets.map(row)],
      updates: batch.updates.map((u, i) => ({
        key: i,
        target: u.target,
        changes: Object.entries(u.changes)
          .filter(([k]) => k !== "assigneeId")
          .map(([k, v]) => `${k}: ${v}`)
          .join("; "),
        comments: u.comments.map((c) => typeof c === "string" ? c : `${c.text}${c.mentions?.length ? "\nMentions (select in Jira): " + c.mentions.map((p) => p.name).join(", ") : ""}`).join("\n\n"),
        reason: u.reason,
      })),
      hasUpdates: batch.updates.length > 0,
      hasItems: batch.epics.length + batch.tickets.length > 0,
      batch: JSON.parse(await prepareBatch({conversationId: this.conversationId, batchJson: JSON.stringify(batch)})),
    };
    this.ticketNote = "";
  }

  handleTicketNote(event) {
    this.ticketNote = event.detail.value;
    this.scheduleDraft();
  }

  async saveTickets() {
    await this.guard(async () => {
      this.assertNotUat();
      // getState reserializes Apex maps; their key order is not a receipt identity.
      // Persist the first request string before applying, then replay it unchanged.
      if (!this.ticketReview.batchJson)
        this.ticketReview = { ...this.ticketReview, batchJson: JSON.stringify(this.ticketReview.batch) };
      const batchJson = this.ticketReview.batchJson;
      this.cacheDraft();
      await this.persistDraft();
      const result = JSON.parse(await this.orgWrite(() => applyBatch({ conversationId: this.conversationId, batchJson })));
      if (typeof result.acknowledgment !== "string" || !result.acknowledgment.trim())
        throw Error("The committed ticket acknowledgment was not returned. Keep this review and retry it to recover the batch receipt.");
      // Apex commits the tickets, receipt and handoff together. Never issue a
      // separate addMessage that could fail after clearing the retry review.
      const supportTicketBug = this.ticketReview.isSupportTicketBug;
      const routingNote = this.ticketReview.supportTicketWarning;
      this.showOutgoing("tickets", result.acknowledgment, "saved");
      this.ticketReview = null;
      this.banner = supportTicketBug
        ? {text: `Saved a local Bug draft in Atlas. It is not in Jira yet. ${routingNote || "You can export it from the Tickets tab."}`}
        : { text: `Saved ${result.saved.length} ticket(s)${result.updates.length ? ` and ${result.updates.length} update(s)` : ""}. Your team sees them on the Tickets tab.` };
      await this.load();
    });
  }

  async rejectTickets() {
    if (!this.ticketNote.trim()) {
      this.problem = { text: "Write a note telling the agent what to change." };
      return;
    }
    await this.guard(async () => {
      await this.send("tickets", notSavedReply(this.ticketNote.trim()));
      this.ticketReview = null;
    });
  }

  // ---- files

  async showFiles(message) {
    let artifacts;
    try {
      artifacts = await this.listFiles(message);
    } catch (e) {
      return this.send("correction", correctionReply(e.message));
    }
    await this.send("files", filesReply(artifacts));
  }

  async listFiles(message, current = () => true) {
    const plan = this.isUat ? checkUatPlan(message, this.conversationId) : null;
    const input = plan ? {type: "atlas-files", artifacts: [uatPlanToArtifact(plan, this.conversationId)]} : message;
    if (!this.isUat && message.type === "atlas-uat-plan") throw Error("UAT plans belong in UAT conversations.");
    return this.presentFiles(input, plan, current);
  }

  // Workspace recovery creates a new parent ID but preserves message bodies. Only
  // messages fetched from this conversation's saved history take this path; live
  // paste and listFiles still require the current ID. Keep provenance in the plan.
  async restoreUatHistory(historyMessage, body, current = () => true) {
    if (!this.isUat || historyMessage?.direction !== "From Agent" || historyMessage.kind !== "atlas-uat-plan") throw Error("Only a saved UAT plan from this conversation's history can be restored.");
    const message = parseAgentJSON(body);
    const plan = checkUatPlan(message, message.requestId);
    const input = {type: "atlas-files", artifacts: [uatPlanToArtifact(plan, plan.requestId)]};
    return this.presentFiles(input, plan, current);
  }

  async presentFiles(input, plan, current) {
    await loadScript(this, FILES);
    if (!current()) return;
    const lib = window.AtlasFiles;
    const artifacts = lib.checkFiles(input);
    this.uatPlan = plan;
    // The file builder takes the agent's definitions exactly; fileReview adds display fields.
    this.artifactsJson = JSON.stringify(artifacts);
    this.fileReview = artifacts.map((a, i) => ({
      ...a,
      key: i,
      isEmail: a.kind === "email",
      emailText: a.kind === "email" ? `Subject: ${a.subject}\n\n${lib.emailText(a)}` : "",
      emailHtml: a.kind === "email" ? lib.emailHTML(a) : "",
      preview: lib.artifactPreview(a),
      icon: a.kind === "email" ? "standard:email" : FILE_ICONS[String(a.name).split(".").pop().toLowerCase()] || "doctype:unknown",
    }));
    this.previewHtml = this.fileReview[0].preview;
    return artifacts;
  }

  previewFile(event) {
    this.previewHtml = this.fileReview[Number(event.currentTarget.dataset.index)].preview;
  }

  renderedCallback() {
    const paste = this.template.querySelector("textarea.atlas-paste");
    if (paste && paste.value !== this.paste) paste.value = this.paste;
    const host = this.template.querySelector(".atlas-preview");
    if (host && host.atlasShown !== this.previewHtml) {
      // Atlas builds the preview HTML from validated text and escapes all of it.
      // eslint-disable-next-line @lwc/lwc/no-inner-html
      host.innerHTML = this.previewHtml || "";
      host.atlasShown = this.previewHtml;
    }
  }

  artifactAt(event) {
    if (this.isUat) {
      if (Number(event.currentTarget.dataset.index) !== 0) throw Error("Choose the validated UAT Word plan.");
      return uatPlanToArtifact(this.uatPlan, this.uatPlan?.requestId);
    }
    return JSON.parse(this.artifactsJson)[Number(event.currentTarget.dataset.index)];
  }

  async downloadArtifact(event) {
    await this.guard(async () => {
      const artifact = this.artifactAt(event);
      const file = await window.AtlasFiles.buildFile(artifact);
      downloadFile(this.template.querySelector("a.atlas-download"), file.name, file.bytes, file.mime);
    });
  }

  async saveToSalesforce(event) {
    await this.guard(async () => {
      const artifact = this.artifactAt(event);
      const file = await window.AtlasFiles.buildFile(artifact);
      // UAT may explicitly save its generated Word document, never arbitrary agent files.
      const save = () => saveFile({ parentId: this.conversationId, fileName: file.name, base64: file.base64 });
      const versionId = this.isUat ? await save() : await this.orgWrite(save);
      this.banner = { text: `${file.name} is saved in Salesforce Files on this conversation.`, url: `/sfc/servlet.shepherd/version/download/${versionId}`, label: "Download it" };
    });
  }
}
