import { LightningElement, api } from "lwc";
import { loadScript } from "lightning/platformResourceLoader";
import FILES from "@salesforce/resourceUrl/Atlas_Files";
import EXTRACT from "@salesforce/resourceUrl/Atlas_Extract";
import startConversation from "@salesforce/apex/Atlas_Data.startConversationChecked";
import conversationPage from "@salesforce/apex/Atlas_Data.conversationPage";
import {writeLibrary as saveEntry, newLibraryIdentity} from "c/atlasStorage";
import { MODE_LABELS, MODES, errorMessage, firstPrompt, downloadFile, UAT_COMPONENT_TYPES, validUatDraft, checkUatIntake } from "c/atlasLib";

const MODE_ICONS = { Source: "utility:apex", Task: "utility:kanban", Files: "utility:file", "support-tickets": "utility:case", uat: "utility:check" };
const MODE_PILLS = { Source: "atlas-pill_accent", Task: "atlas-pill_epic", Files: "atlas-pill_success", "support-tickets": "atlas-pill_warning", uat: "atlas-pill_success" };
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
const DAY = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" });
// Getters run on every render, so the sorted list is rebuilt only when something it reads changes.
const listCache = new WeakMap();
const object = (value) => !!value && typeof value === "object" && !Array.isArray(value);
const validDraft = (draft) => object(draft) && ["mode", "title", "request", "nonce"].every((key) => draft[key] === undefined || typeof draft[key] === "string")
  && validUatDraft(draft.uat)
  && (draft.attachments === undefined || Array.isArray(draft.attachments) && draft.attachments.every((a) => object(a) && typeof a.name === "string" && (a.warnings === undefined || Array.isArray(a.warnings) && a.warnings.every((w) => typeof w === "string"))))
  && (draft.pendingDrafts === undefined || Array.isArray(draft.pendingDrafts) && draft.pendingDrafts.every(object))
  && (draft.startPending == null || object(draft.startPending) && ["conversationJson", "prompt", "nonce"].every((key) => typeof draft.startPending[key] === "string"));

export default class AtlasWork extends LightningElement {
  @api boot;
  @api settings;
  selectedId;
  creating = false;
  showClosed = false;
  form = { mode: "Source", title: "", request: "" };
  attachments = [];
  extractionRun;
  extractionProgress = "";
  get extracting() { return !!this.extractionRun; }
  get startDisabled() { return this.busy || this.extracting; }
  busy = false;
  error;
  savedNotice = "";
  pages = [];
  cursor;
  paged = false;
  nonce = "";
  pendingDrafts = [];
  startPending = null;
  libraryDraft = null;
  get hasPendingDraft() { return this.pendingDrafts.length > 0; }
  get pendingDraftTitle() { return this.pendingDrafts[0]?.title || "Imported draft"; }
  get hasUnsentDraft() { return !!(this.form.title || this.form.request || Object.values(this.form.uat || {}).some(Boolean) || this.attachments.length); }
  get isUat() { return this.form.mode === "uat"; }
  get uat() { return this.form.uat || {}; }
  get isUatOther() { return this.uat.componentType === "Other"; }
  get uatOptions() { return UAT_COMPONENT_TYPES.map((value) => ({label: value, value})); }
  get requestLimit() { return this.isUat ? 30000 : undefined; }
  handleUatField(event) {
    if (this.editingLocked) return;
    this.form = {...this.form, uat: {...this.uat, [event.target.name]: event.detail.value ?? event.target.value}};
    this.cacheDraft();
  }
  get editingLocked() { return this.busy || !!this.startPending; }
  get attachmentRows() { return this.attachments.map((a) => ({...a, warning: (a.warnings || []).join(" ")})); }
  get awaitingStart() { return !!this.startPending; }
  get draftKey() { return this.boot?.org?.id && this.boot?.user?.id ? `atlas-new:${this.boot.org.id}:${this.boot.user.id}` : null; }
  connected = false;
  hydrated = false;
  connectedCallback() {
    this.loadPage();
    if (!this.hydrated && this.draftKey) {
      try {
        const draft = JSON.parse(sessionStorage.getItem(this.draftKey) || "null");
        if (draft) {
          if (!object(draft) || !validDraft(draft) || !object(draft.form) || !validDraft(draft.form)
            || (draft.pendingDrafts || []).some((item) => !validDraft(item))
            || (draft.libraryDraft != null && (!object(draft.libraryDraft) || !["creationKey", "fingerprint"].every((key) => typeof draft.libraryDraft[key] === "string")))) throw Error("Invalid browser draft");
          this.form = {mode: "Source", title: "", request: "", ...draft.form}; this.attachments = draft.attachments || []; this.nonce = draft.nonce || "";
          this.pendingDrafts = [...(draft.pendingDrafts || []), ...this.pendingDrafts]; this.startPending = draft.startPending || null;
          this.libraryDraft = draft.libraryDraft || null;
          this.creating = !this.selectedId; this.savedNotice = "Recovered the unsent conversation from this browser.";
        }
      } catch { this.savedNotice = "Browser draft recovery is unavailable. Save or download drafts before leaving."; }
      this.hydrated = true;
    }
    this.connected = true;
    if (this._openRequest?.draft) this.acceptPendingDraft();
  }
  disconnectedCallback() { this.connected = false; this.stopExtraction(); }
  acceptPendingDraft() {
    this.newConversation();
    this.cacheDraft();
    if (!this.hasUnsentDraft && !this.editingLocked) this.openPendingDraft();
  }
  loadingPage = false;
  async loadPage() {
    if (this.loadingPage || (this.paged && !this.cursor)) return;
    this.loadingPage = true;
    try {
      const page = JSON.parse(await conversationPage({afterId: this.cursor || null}));
      this.pages = [...this.pages, ...page.rows]; this.cursor = page.cursor; this.paged = true;
    } catch (e) { this.error = errorMessage(e); }
    finally { this.loadingPage = false; }
  }
  cacheDraft() {
    if (!this.nonce) this.nonce = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    if (!this.connected || !this.draftKey) return false;
    try {
      sessionStorage.setItem(this.draftKey, JSON.stringify({form: this.form, attachments: this.attachments, nonce: this.nonce, pendingDrafts: this.pendingDrafts, startPending: this.startPending, libraryDraft: this.libraryDraft}));
      return true;
    } catch { this.savedNotice = "Browser could not save the draft. Download it or keep this tab open before leaving."; return false; }
  }
  draftJSON() { return JSON.stringify({...this.form, attachments: this.attachments, pendingDrafts: this.pendingDrafts, startPending: this.startPending, nonce: this.nonce}); }
  async persistDraft() {
    this.cacheDraft();
    const dataJson = this.draftJSON(), title = (this.form.title || "Unsent conversation").slice(0,80);
    const request = {recordId: null, title, kind: "draft", expectedRevision: 0, dataJson};
    if (new TextEncoder().encode(dataJson).length <= 1000000) {
      const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([title, dataJson])));
      const fingerprint = Array.from(new Uint8Array(digest), (n) => n.toString(16).padStart(2, "0")).join("");
      // The hash compares only this draft's snapshot; a new draft gets its own identity.
      if (this.libraryDraft?.fingerprint !== fingerprint) this.libraryDraft = {creationKey: newLibraryIdentity(), fingerprint};
      if (!this.cacheDraft()) throw Error("Draft creation identity could not be saved in this browser tab. Download the draft and keep this tab open; no network write was attempted.");
      request.creationKey = this.libraryDraft.creationKey;
    }
    await saveEntry(request);
    this.savedNotice = "Draft saved to Library & recovery. You can reopen it there on any computer.";
  }
  async saveDraft() {
    if (this.busy) return;
    this.busy = true;
    try { await this.persistDraft(); }
    catch (e) { this.error = errorMessage(e); }
    finally { this.busy = false; }
  }
  async openPendingDraft() {
    if (this.editingLocked || !this.hasPendingDraft) return;
    this.stopExtraction();
    this.busy = true;
    try {
      if (!validDraft(this.pendingDrafts[0]) || (this.pendingDrafts[0].pendingDrafts || []).some((item) => !validDraft(item))) throw Error("This recovered conversation draft has invalid fields. Download the current draft and inspect the recovery before retrying.");
      if (this.hasUnsentDraft) await this.persistDraft();
      const [draft, ...remaining] = this.pendingDrafts;
      const {attachments = [], pendingDrafts = [], startPending = null, nonce = "", ...form} = draft;
      this.form = {mode: "Source", title: "", request: "", ...form};
      this.attachments = attachments;
      this.pendingDrafts = [...pendingDrafts, ...remaining];
      this.startPending = startPending; this.nonce = nonce; this.libraryDraft = null;
      this.creating = true; this.selectedId = null; this.error = null;
      this.cacheDraft();
    } catch (e) { this.error = errorMessage(e); }
    finally { this.busy = false; }
  }
  async saveAndNew() {
    if (this.editingLocked) return;
    this.stopExtraction();
    this.busy = true;
    try {
      if (this.hasUnsentDraft) await this.persistDraft();
      this.form = {mode: "Source", title: "", request: ""}; this.attachments = []; this.nonce = ""; this.libraryDraft = null;
      this.cacheDraft(); this.newConversation();
    } catch (e) { this.error = errorMessage(e); }
    finally { this.busy = false; }
  }
  downloadDraft() { downloadFile(this.template.querySelector("a.atlas-download"), "Atlas-new-conversation.json", this.draftJSON(), "application/json"); }

  /** {id} opens a conversation; {draft: {mode, title, request}} fills in a new one. */
  @api
  get openRequest() {
    return this._openRequest;
  }
  set openRequest(value) {
    this._openRequest = value;
    if (value?.id) {
      this.stopExtraction();
      this.selectedId = value.id;
      this.creating = false;
    } else if (value?.draft) {
      this.pendingDrafts = [...this.pendingDrafts, value.draft];
      if (this.connected) this.acceptPendingDraft();
    }
  }

  get modeOptions() {
    return Object.entries(MODES).map(([value, label]) => ({
      value, label, displayLabel: MODE_LABELS[value] || value, ariaLabel: `${MODE_LABELS[value] || value}: ${label}`, icon: MODE_ICONS[value] || "utility:chat", checked: this.form.mode === value,
      className: "atlas-mode" + (this.form.mode === value ? " atlas-mode_active" : "")
    }));
  }
  filter = "";
  get conversations() {
    const inputs = [this.pages, this.boot?.conversations, this.filter, this.showClosed, this.selectedId];
    const cached = listCache.get(this);
    if (cached && cached.inputs.every((value, i) => value === inputs[i])) return cached.rows;
    const rows = new Map(this.pages.map((c) => [c.id, c]));
    for (const c of this.boot?.conversations || []) rows.set(c.id, c);
    const needle = this.filter.trim().toLowerCase();
    const list = [...rows.values()].map((c) => ({ c, time: Date.parse(c.updated) || 0 }))
      .sort((a, b) => b.time - a.time)
      .filter(({ c }) => this.showClosed || c.status !== "Closed")
      .filter(({ c }) => !needle || `${c.title} ${c.mode} ${MODE_LABELS[c.mode] || c.mode}`.toLowerCase().includes(needle))
      .map(({ c, time }) => ({
        ...c,
        modeLabel: MODE_LABELS[c.mode] || c.mode,
        className: "atlas-conversation" + (c.id === this.selectedId ? " atlas-conversation_active" : ""),
        current: c.id === this.selectedId ? "page" : null,
        modeClass: "atlas-pill " + (MODE_PILLS[c.mode] || ""),
        date: time ? DAY.format(time) : "",
        closed: c.status === "Closed",
      }));
    listCache.set(this, { inputs, rows: list });
    return list;
  }
  get conversationCount() {
    return this.conversations.length + (this.cursor ? "+" : "");
  }
  get emptyListText() {
    return this.filter.trim() ? "No loaded conversation matches this filter." : "No conversations yet.";
  }
  get listError() {
    return this.error && !this.creating;
  }
  handleFilter(event) {
    this.filter = event.detail.value || "";
  }
  handleMode(event) {
    if (this.editingLocked) return;
    this.form = { ...this.form, mode: event.target.value };
    this.cacheDraft();
  }
  handleDraftMenu(event) {
    if (event.detail.value === "fresh") this.saveAndNew();
    else this.downloadDraft();
  }
  // A one-item list: LWC honours key only inside for:each, so each conversation gets a fresh panel.
  get openConversation() {
    return this.selectedId ? [this.selectedId] : [];
  }
  get noConversations() {
    return this.conversations.length === 0;
  }
  get showWelcome() {
    return !this.creating && !this.selectedId;
  }
  get closedLabel() {
    return this.showClosed ? "Hide closed" : "Show closed";
  }
  get hasAttachments() {
    return this.attachments.length > 0;
  }

  newConversation() {
    this.stopExtraction();
    this.creating = true;
    this.selectedId = null;
    this.error = null;
    this.scrollDetailTop();
  }
  scrollDetailTop() {
    const detail = this.template?.querySelector(".atlas-detail");
    if (detail) detail.scrollTop = 0;
  }
  cancelNew() {
    this.stopExtraction();
    this.creating = false;
  }
  toggleClosed() {
    this.showClosed = !this.showClosed;
  }
  select(event) {
    event.preventDefault();
    this.stopExtraction();
    this.selectedId = event.currentTarget.dataset.id;
    this.creating = false;
    this.scrollDetailTop();
  }
  handleField(event) {
    if (this.editingLocked) return;
    this.form = { ...this.form, [event.target.name]: event.detail.value ?? event.target.value };
    this.cacheDraft();
  }

  stopExtraction(message = "") {
    const run = this.extractionRun;
    if (!run) return;
    this.extractionRun = null;
    clearTimeout(run.timer);
    run.stop();
    run.job?.cancel();
    this.extractionProgress = message;
  }
  cancelExtraction() { this.stopExtraction("Extraction cancelled. Previously accepted attachments are unchanged; this selection was not saved."); }
  async handleFiles(event) {
    const files = [...(event.target.files || [])];
    event.target.value = "";
    if (this.editingLocked || !files.length) return;
    this.stopExtraction();
    const run = {};
    const stopped = new Promise((resolve) => { run.stop = resolve; });
    this.extractionRun = run;
    this.extractionProgress = "Loading background extractor…";
    this.error = null;
    run.timer = setTimeout(() => {
      if (this.extractionRun === run) this.stopExtraction("Background extractor loading timed out. This selection was not saved; retry or contact the administrator.");
    }, 60000);
    try {
      await Promise.race([loadScript(this, FILES), stopped]);
      if (this.extractionRun !== run) return;
      clearTimeout(run.timer);
      if (!window.AtlasFiles?.startDocumentExtraction) throw Error("Rebuild the Atlas Files and Extract static resources before extracting documents.");
      const pending = [];
      for (const [index, file] of files.entries()) {
        if (file.size > MAX_ATTACHMENT_BYTES) throw new Error(`${file.name} is larger than 25 MB.`);
        const label = `${index + 1}/${files.length} — ${file.name}: `;
        run.job = window.AtlasFiles.startDocumentExtraction(file, { workerUrl: EXTRACT, host: this.template.querySelector(".atlas-extraction-host"), mode: "attachment",
          onProgress: (text) => { if (this.extractionRun === run) this.extractionProgress = label + text; } });
        const doc = await Promise.race([run.job.promise, stopped]);
        if (this.extractionRun !== run) return;
        pending.push({ key: file.name + Date.now() + "-" + index, name: file.name, kind: doc.kind, text: doc.text, warnings: doc.warnings || [], size: `${doc.text.length.toLocaleString()} characters` });
      }
      // Accept the whole selection once. Cancellation/failure cannot autosave a partial batch.
      this.attachments = [...this.attachments, ...pending];
      this.cacheDraft();
      this.extractionProgress = `${pending.length} attachment(s) accepted. Review their extraction warnings.`;
    } catch (e) {
      if (this.extractionRun === run) {
        this.error = "Could not read the attachment: " + errorMessage(e);
        this.extractionProgress = "This selection was not saved. Previously accepted attachments are unchanged.";
      }
    } finally {
      if (this.extractionRun === run) {
        clearTimeout(run.timer);
        run.job?.cancel();
        this.extractionRun = null;
      }
    }
  }
  removeAttachment(event) {
    if (this.editingLocked) return;
    const key = event.currentTarget.dataset.key;
    this.attachments = this.attachments.filter((a) => a.key !== key);
    this.cacheDraft();
  }

  async start() {
    if (this.startDisabled) return;
    if (!this.startPending && !this.form.title.trim()) {
      this.error = "Give the conversation a short title.";
      return;
    }
    this.busy = true;
    this.error = null;
    try {
      if (!this.startPending && this.isUat) this.form = {...this.form, uat: checkUatIntake(this.form)};
      this.cacheDraft();
      const created = !this.startPending;
      if (created) this.startPending = {
        conversationJson: JSON.stringify({...this.form, uat: this.isUat ? this.form.uat : undefined, status: "Open"}),
        prompt: firstPrompt({conversation: this.form, boot: this.boot, mine: this.settings.mine, jira: this.settings.jira, attachments: this.attachments}),
        nonce: this.nonce,
      };
      // A retry finds its conversation by this saved identity. Without it, a lost
      // reply followed by a reload would start a second conversation.
      if (!this.cacheDraft()) {
        if (created) this.startPending = null;
        throw Error(`The conversation was not started: this browser tab could not save its retry identity. Nothing was sent to Salesforce. ${created ? "Remove large attachments or free browser storage" : "Download the draft and free browser storage"}, then start again.`);
      }
      const id = await startConversation(this.startPending);
      if (typeof id !== "string" || !/^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/.test(id)) {
        let rejected;
        try { rejected = JSON.parse(id); } catch { /* Unknown replies remain uncertain. */ }
        if (rejected?.code !== "ATLAS_START_INPUT_REJECTED" || typeof rejected.message !== "string" || !rejected.message) throw Error("Start returned an unrecognized response. Retry the unchanged request to recover its outcome.");
        // This server response is issued only before any writes for inputs that cannot commit.
        this.startPending = null; this.nonce = "";
        this.cacheDraft();
        this.error = rejected.message;
        return;
      }
      this.startPending = null; this.nonce = ""; this.libraryDraft = null;
      this.form = {mode: "Source", title: "", request: ""}; this.attachments = [];
      this.cacheDraft();
      this.creating = false;
      this.selectedId = id;
      this.dispatchEvent(new CustomEvent("refresh"));
    } catch (e) {
      this.error = errorMessage(e);
    } finally {
      this.busy = false;
    }
  }

  handleConversationChanged() {
    this.dispatchEvent(new CustomEvent("refresh"));
  }
}
