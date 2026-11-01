import { LightningElement } from "lwc";
import { exportWorkspace, validateArchive, prepareRecovery, applyRecovery, resumeReview, openArchive,
  preserveArchive, errorText, ARCHIVE_LIMIT } from "c/atlasWorkspaceLib";

export default class AtlasWorkspace extends LightningElement {
  busy = false;
  problem = "";
  message = "";
  pending = null;
  review = null;
  acknowledged = false;
  page = 0;
  referenceJson = "{}";
  archiveId = "";
  archiveVersionId = "";
  planId = "";
  cancelled = false;
  exporting = false;
  exportRaw = "";
  receipts = [];

  get hasArchive() { return Boolean(this.pending); }
  get hasExport() { return Boolean(this.exportRaw); }
  get hasReview() { return Boolean(this.review); }
  get hasReceipts() { return this.receipts.length > 0; }
  get archiveSummary() {
    const a = this.pending?.archive;
    if (!a) return "";
    return `${a.records.length} native records · ${a.files.length} immutable File versions · ${a.completeness.complete ? "Complete within the declared readable, own-data scope" : "INCOMPLETE: inspect omissions; affected selections are blocked"}. This is not an atomic snapshot.`;
  }
  get scopeText() { return this.pending ? JSON.stringify({ scope: this.pending.archive.scope, completeness: this.pending.archive.completeness,
    inaccessibleFields: Object.fromEntries(Object.entries(this.pending.archive.schemas).map(([key, value]) => [key, value.inaccessibleFields || value.error || []])) }, null, 2) : ""; }
  get rows() {
    return (this.pending?.archive.records || []).slice(this.page * 25, (this.page + 1) * 25).map((record) => ({
      id: record.id, type: record.type, title: record.values.Name || record.values.Summary__c || record.id,
      label: record.type === "Atlas_Change__c" || (record.type === "Atlas_Library__c" && record.values.Kind__c === "upload") ? "Review inert history" : "Review additive recovery"
    }));
  }
  get previousDisabled() { return this.busy || this.page === 0; }
  get nextDisabled() { return this.busy || (this.page + 1) * 25 >= (this.pending?.archive.records.length || 0); }
  get applyDisabled() { return this.busy || !this.acknowledged || !this.review || this.review.conflicts.length > 0 || this.review.status === "applied"; }
  get reviewText() { return this.review ? JSON.stringify(this.review, null, 2) : ""; }
  get reviewSummary() { return this.review ? `${this.review.mode} · ${this.review.conflicts.length} blocking conflict(s) · immutable review ${this.review.versionId}` : ""; }
  get receiptText() { return JSON.stringify(this.receipts, null, 2); }

  async action(work) {
    if (this.busy) return;
    this.busy = true;
    this.problem = "";
    try { await work(); }
    catch (error) { this.problem = errorText(error); }
    finally { this.busy = false; }
  }
  progress = (message) => { this.message = message; };
  input(event) {
    if (this.busy) return;
    const field = event.target.dataset.field;
    if (["referenceJson", "archiveId", "archiveVersionId", "planId"].includes(field)) this[field] = event.detail?.value ?? event.target.value;
    if (field === "referenceJson") { this.review = null; this.acknowledged = false; }
  }
  acknowledge(event) { if (!this.busy) this.acknowledged = event.target.checked; }
  previous() { if (!this.previousDisabled) this.page--; }
  next() { if (!this.nextDisabled) this.page++; }
  cancelExport() { if (this.exporting) this.cancelled = true; }
  exportOwn() {
    return this.action(async () => {
      this.cancelled = false;
      this.exporting = true;
      try {
        const result = await exportWorkspace(this.progress, () => this.cancelled);
        this.exportRaw = result.raw;
        this.download("atlas-native-workspace.json", result.raw);
        this.message = `${result.archive.completeness.complete ? "Own-data backup" : "INCOMPLETE diagnostic backup"} download requested. Verify the downloaded file; keep this unencrypted data private. No server data was written.`;
      } finally { this.exporting = false; }
    });
  }
  download(name, raw) {
    const url = URL.createObjectURL(new Blob([raw], { type: "application/json" }));
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  downloadExport() { if (this.exportRaw) this.download("atlas-native-workspace.json", this.exportRaw); }
  downloadReview() { if (this.review) this.download("atlas-recovery-review.json", this.reviewText); }
  downloadReceipts() { if (this.hasReceipts) this.download("atlas-recovery-receipts.json", this.receiptText); }
  adopt(pending) {
    this.pending = pending;
    this.review = null;
    this.acknowledged = false;
    this.referenceJson = "{}";
    this.page = 0;
    this.message = "Native archive validated locally. No records or Files were written. Choose one record; recover its referenced parents first or provide explicit mappings.";
  }
  importFile(event) {
    const file = event.target.files?.[0];
    if (!file || this.busy) return;
    return this.action(async () => {
      if (file.size > ARCHIVE_LIMIT) throw Error("Native archive exceeds 100 MiB. Nothing was imported.");
      const raw = await file.text();
      this.adopt({ raw, archive: await validateArchive(raw), saved: null });
    });
  }
  openSaved() {
    return this.action(async () => this.adopt(await openArchive(this.archiveId.trim(), this.archiveVersionId.trim())));
  }
  saveSource() {
    return this.action(async () => {
      if (!this.pending) return;
      const saved = await preserveArchive(this.pending, this.progress);
      this.message = `Exact source preserved privately as ${saved.id}, immutable version ${saved.versionId}. Native records have not been recovered.`;
    });
  }
  prepare(event) {
    if (this.busy) return;
    const recordId = event.currentTarget.dataset.id;
    return this.action(async () => {
      this.review = null;
      this.acknowledged = false;
      this.review = await prepareRecovery(this.pending, recordId, JSON.parse(this.referenceJson), this.progress);
      this.planId = this.review.id;
      this.message = `Source, before-state and staged Files preserved privately. Review ${this.review.id}; no native record has been inserted. Read all conflicts/notices before confirming.`;
    });
  }
  resume() {
    return this.action(async () => {
      this.acknowledged = false;
      this.review = await resumeReview(this.planId.trim());
      this.message = "Saved immutable recovery review reopened. Re-check the exact fields, mappings and conflicts before applying.";
    });
  }
  apply() {
    if (this.applyDisabled) return;
    return this.action(async () => {
      const receipt = await applyRecovery(this.review);
      this.receipts = [...this.receipts, receipt];
      if (receipt.mode === "insert") this.referenceJson = JSON.stringify({ ...JSON.parse(this.referenceJson), [receipt.sourceId]: receipt.recordId }, null, 2);
      this.review = { ...this.review, status: "applied" };
      this.acknowledged = false;
      this.message = `Recovered ${receipt.mode === "insert" ? "one new native record" : "inert history only"}: ${receipt.recordId}. Private before-state/history: ${receipt.historyId}. Existing records unchanged; no jobs restarted or deployed.`;
      this.dispatchEvent(new CustomEvent("recovered", { detail: receipt }));
    });
  }
}
