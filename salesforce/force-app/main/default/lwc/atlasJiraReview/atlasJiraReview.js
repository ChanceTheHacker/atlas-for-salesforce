import { LightningElement, api } from "lwc";
import approveWrite from "@salesforce/apex/Atlas_JiraWrites.approveWrite";
import getWrite from "@salesforce/apex/Atlas_JiraWrites.getWrite";
import { errorMessage } from "c/atlasLib";

const TERMINAL_STATES = new Set(["succeeded", "failed", "unknown", "invalidated"]);
const POLL_INTERVAL_MS = 2000;
const MAX_POLLS = 30;

function parseOperation(raw) {
  const value = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (!value || typeof value !== "object" || Array.isArray(value) || typeof value.id !== "string" || !value.id) {
    throw new Error("Jira returned an invalid write operation.");
  }
  return value;
}

function formatValue(value, emptyText) {
  if (value == null) return emptyText;
  if (typeof value === "string") {
    try { return JSON.stringify(JSON.parse(value), null, 2); }
    catch { return value || emptyText; }
  }
  return JSON.stringify(value, null, 2);
}

export default class AtlasJiraReview extends LightningElement {
  _operation;
  @api disabled = false;
  @api contextLabel = "";
  working = false;
  confirmed = false;
  error = "";
  pollNotice = "";
  pollTimer;
  pollAttempts = 0;
  requestGeneration = 0;

  @api get operation() { return this._operation; }
  set operation(value) {
    const previousId = this._operation?.id;
    const previousState = this._operation?.state;
    const previousRevision = this._operation?.revision;
    this._operation = value ? { ...value } : null;
    const changedId = this._operation?.id !== previousId;
    const changedState = this._operation?.state !== previousState;
    const changedRevision = this._operation?.revision !== previousRevision;
    if (changedId) {
      this.confirmed = false;
      this.error = "";
      this.pollNotice = "";
      this.pollAttempts = 0;
      this.requestGeneration++;
      clearTimeout(this.pollTimer);
    } else if (changedState || changedRevision) {
      this.confirmed = false;
    }
    if (this.isConnected && this._operation?.id) {
      if (changedId && this._operation.state === "loading") this.refresh();
      else if (this._operation.state === "queued") this.schedulePoll();
    }
  }

  connectedCallback() {
    if (!this._operation?.id) return;
    if (this._operation.state === "loading") this.refresh();
    else if (this._operation.state === "queued") this.schedulePoll();
  }

  disconnectedCallback() {
    this.requestGeneration++;
    clearTimeout(this.pollTimer);
  }

  get state() { return this._operation?.state || "loading"; }
  get hasOperation() { return !!this._operation?.id; }
  get hasFullReview() {
    return !!this._operation && this.hasDestination && Object.prototype.hasOwnProperty.call(this._operation, "payload");
  }
  get needsFullReview() { return this.hasOperation && this.state !== "loading" && !this.hasFullReview; }
  get isReviewed() { return this.state === "reviewed"; }
  get isQueued() { return this.state === "queued"; }
  get isUnknown() { return this.state === "unknown"; }
  get isTerminal() { return TERMINAL_STATES.has(this.state); }
  get hasDestination() { return !!(this._operation?.destination || this._operation?.apiBaseUrl || /^https?:\/\//i.test(this._operation?.path || "")); }
  get canApprove() { return this.isReviewed && this.hasFullReview && !this.disabled && !this.working; }
  get needsConfirmation() { return this.isReviewed && this.hasFullReview; }
  get showStatusCheck() { return this.isQueued || this.isUnknown; }
  get viewFullReviewDisabled() { return this.disabled || this.working; }
  get statusLabel() {
    return ({
      loading: "Loading the saved Jira write. No request will be sent while its status is unknown.",
      reviewed: this.hasFullReview ? "Ready for your approval. Jira has not received this request." : "A saved preview awaits review. Load the exact request before approval; Jira has not received it.",
      queued: "Queued. Jira has not yet confirmed completion.",
      succeeded: "Jira confirmed this write succeeded.",
      failed: "Jira reported that this write failed.",
      unknown: "The outcome is unknown. Do not send this write again.",
      invalidated: "This preview is no longer valid and cannot be approved.",
    })[this.state] || `Jira write state: ${this.state}. No automatic action will be taken.`;
  }
  get statusClass() {
    if (this.state === "succeeded") return "atlas-notice atlas-notice_success";
    if (this.state === "failed" || this.state === "invalidated" || this.state === "unknown") return "atlas-notice atlas-notice_warning";
    return "atlas-notice atlas-notice_neutral";
  }
  get operationLabel() {
    const operation = this._operation?.operation;
    const labels = { create: "ticket creation", update: "ticket update", comment: "ticket comment", transition: "status change" };
    return labels[operation] || operation || "Jira write";
  }
  get approvalLabel() {
    const label = this.contextLabel || `${this.operationLabel} ${this.shortId}`;
    return `Approve ${label} in Jira`;
  }
  get confirmationLabel() {
    const label = this.contextLabel || `${this.operationLabel} ${this.shortId}`;
    return `I reviewed and approve sending ${label} to Jira`;
  }
  get statusButtonLabel() { return `Check status for Jira write ${this.shortId}`; }
  get shortId() { return this._operation?.id?.slice(-8) || "operation"; }
  get requestLine() {
    const method = this._operation?.method || "Request";
    const path = this._operation?.path || "path not supplied";
    return `${method} ${path}`;
  }
  get destinationText() {
    const path = this._operation?.path || "";
    if (this._operation?.destination) return this._operation.destination;
    if (/^https?:\/\//i.test(path)) return path;
    const base = this._operation?.apiBaseUrl || this._operation?.siteUrl;
    if (!base) return this.needsFullReview ? "Select ‘View saved Jira request’ to load the saved destination." : "Not supplied by the backend review.";
    return path ? `${base.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}` : base;
  }
  get namedCredentialText() { return this._operation?.namedCredential || "Not supplied by the backend review."; }
  get externalCredentialText() { return this._operation?.externalCredential || "Not supplied by the backend review."; }
  get requestId() { return this._operation?.requestId || "Not supplied"; }
  get payloadText() {
    if (!this.hasFullReview) return "The full request is not loaded. Select ‘View saved Jira request’ to retrieve it.";
    return formatValue(this._operation?.payload, "No request body was returned.");
  }
  get resultText() { return formatValue(this._operation?.result, "No Jira result is available yet."); }
  get hasResult() { return this._operation?.result != null; }
  get operationMessage() { return this._operation?.message || ""; }
  get approveDisabled() { return !this.canApprove || !this.confirmed; }

  handleConfirmation(event) { this.confirmed = event.detail.checked === true; }

  publish() {
    this.dispatchEvent(new CustomEvent("changed", {
      detail: { operation: this._operation },
    }));
  }

  setOperation(value) {
    const operation = parseOperation(value);
    if (operation.id !== this._operation?.id) {
      this.confirmed = false;
      this.pollAttempts = 0;
      this.pollNotice = "";
    } else if (operation.state !== this._operation?.state || operation.revision !== this._operation?.revision) {
      this.confirmed = false;
    }
    this._operation = operation;
    this.error = "";
    if (TERMINAL_STATES.has(operation.state)) {
      clearTimeout(this.pollTimer);
      this.pollNotice = "";
    } else if (operation.state === "queued") {
      this.schedulePoll();
    } else {
      clearTimeout(this.pollTimer);
    }
    this.publish();
  }

  async refresh({ afterApprovalError = false, fullReview = false } = {}) {
    if (!this._operation?.id || this.working) return;
    const operationId = this._operation.id;
    const generation = ++this.requestGeneration;
    this.working = true;
    this.error = "";
    try {
      const result = parseOperation(await getWrite({ operationId }));
      if (generation !== this.requestGeneration || this._operation?.id !== operationId) return;
      this.setOperation(result);
    } catch (e) {
      if (generation !== this.requestGeneration || this._operation?.id !== operationId) return;
      const message = fullReview
        ? `Could not load the full saved Jira request. No write was sent. ${errorMessage(e)}`
        : `Could not confirm Jira write status. No write was resent. ${errorMessage(e)}`;
      if (afterApprovalError || this.state === "loading") {
        this.setOperation({ ...this._operation, state: "unknown", message });
      } else {
        this.error = message;
        if (this.isQueued) this.schedulePoll();
      }
    } finally {
      if (generation === this.requestGeneration) this.working = false;
    }
  }

  async approve() {
    if (!this.canApprove || !this.confirmed) return;
    const operationId = this._operation.id;
    const expectedRevision = this._operation.revision;
    const generation = ++this.requestGeneration;
    this.working = true;
    this.error = "";
    try {
      const result = parseOperation(await approveWrite({ operationId, expectedRevision }));
      if (generation !== this.requestGeneration || this._operation?.id !== operationId) return;
      this.setOperation(result);
    } catch (e) {
      if (generation !== this.requestGeneration || this._operation?.id !== operationId) return;
      const message = `The approval response was not confirmed. Checking the saved operation before any further action. ${errorMessage(e)}`;
      this.setOperation({ ...this._operation, state: "unknown", message });
      this.working = false;
      await this.refresh({ afterApprovalError: true });
    } finally {
      if (generation === this.requestGeneration) this.working = false;
    }
  }

  viewSavedReview() {
    if (!this.needsFullReview || this.viewFullReviewDisabled) return;
    return this.refresh({ fullReview: true });
  }

  checkStatus() { return this.refresh(); }

  schedulePoll() {
    clearTimeout(this.pollTimer);
    if (!this.isConnected || !this.isQueued || this.pollAttempts >= MAX_POLLS) {
      if (this.isQueued && this.pollAttempts >= MAX_POLLS) this.pollNotice = "This write is still queued. No second request was sent; check its status again later.";
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.pollAttempts++;
      this.refresh();
    }, POLL_INTERVAL_MS);
  }
}
