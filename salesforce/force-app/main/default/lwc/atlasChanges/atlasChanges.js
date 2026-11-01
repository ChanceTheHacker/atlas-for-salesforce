import { LightningElement, api } from "lwc";
import changePage from "@salesforce/apex/Atlas_Changes.changePage";
import getChange from "@salesforce/apex/Atlas_Changes.getChange";
import deployStatus from "@salesforce/apex/Atlas_Changes.deployStatus";
import restorePlan from "@salesforce/apex/Atlas_Changes.restorePlan";
import startRestore from "@salesforce/apex/Atlas_Changes.startRestore";
import componentIndex from "@salesforce/apex/Atlas_Versions.componentIndex";
import componentHistory from "@salesforce/apex/Atlas_Versions.componentHistory";
import storagePlan from "@salesforce/apex/Atlas_Versions.storagePlan";
import freeStorage from "@salesforce/apex/Atlas_Versions.freeStorage";
import reconcileDeployment from "@salesforce/apex/Atlas_Changes.reconcileDeployment";
import { TEST_LEVELS, errorMessage, pollDelay } from "c/atlasLib";

const RUNNING = ["Deploying", "Restoring"];
// eslint-disable-next-line @lwc/lwc/no-async-operation
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const RESTORABLE = ["Deployed", "Failed", "Restored"];
const VIEWS = [{ label: "All changes", value: "changes" }, { label: "Component history", value: "history" }];
const STORAGE_AGES = [30, 90, 180, 365].map((days) => ({ label: `Older than ${days} days`, value: String(days) }));
const UNDONE_SHOWN = 5;

function size(bytes = 0) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}
const when = (value) => (value ? new Date(value).toLocaleString() : "");

function statusPill(status = "") {
  if (status === "Proposed") return "atlas-pill atlas-pill_warning";
  if (/Deployed|Restored/.test(status)) return "atlas-pill atlas-pill_success";
  if (/Fail|Reject|Unknown/.test(status)) return "atlas-pill atlas-pill_danger";
  if (/ing$/.test(status)) return "atlas-pill atlas-pill_accent";
  return "atlas-pill";
}

export default class AtlasChanges extends LightningElement {
  @api boot;
  @api settings;
  changes = [];
  cursor = null;
  generation = 0;
  get hasMore() { return !!this.cursor; }
  loaded = false;
  selected;
  busy = false;
  error;
  confirmRestore = false;
  restoreLevel;
  progress = "";
  watchingId;
  selectionEpoch = 0;
  busyToken;
  restoreTarget;
  view = "changes";
  componentList;
  history;
  historyKey;
  storageOpen = false;
  storageDays = "90";
  storage;
  storageDone = "";
  storageToken;
  indexToken;
  invalidateSelection() {
    this.selectionEpoch++;
    this.generation++;
    this.watchingId = null;
    this.progress = "";
    this.cancelRestore();
    this.restoreLevel = undefined;
    this.deploymentId = "";
    this.busyToken = null;
    this.busy = false;
    this.error = null;
    return this.selectionEpoch;
  }
  currentSelection(epoch, id) { return epoch === this.selectionEpoch && this.selected?.id === id; }
  deploymentId = "";
  activationConfirmed = false;
  get outcomeUnknown() { return this.selected?.result?.outcomeUnknown === true; }
  handleDeploymentId(event) { this.deploymentId = event.detail.value; }
  handleActivation(event) { if (this.restoreTarget) this.activationConfirmed = event.target.checked; }
  get viewOptions() { return VIEWS; }
  get showChanges() { return this.view === "changes"; }
  get showHistory() { return this.view === "history"; }
  handleView(event) {
    const view = event.detail.value;
    if (view === this.view) return;
    this.cancelRestore();
    this.view = view;
    if (view === "history") {
      this.loadIndex();
      if (this.historyKey) this.loadHistory(this.historyKey, this.selectionEpoch);
    } else if (this.selected && this.isRunning && !this.outcomeUnknown) this.watch();
  }
  async reconcile() {
    if (this.busy || !this.selected || !this.outcomeUnknown) return;
    const changeId = this.selected.id, deploymentId = this.deploymentId.trim();
    const epoch = this.invalidateSelection();
    await this.guard(async () => {
      const selected = JSON.parse(await reconcileDeployment({changeId, deploymentId}));
      if (this.currentSelection(epoch, changeId)) this.selected = selected;
    }, undefined, epoch);
    if (this.currentSelection(epoch, changeId) && this.isRunning && !this.outcomeUnknown) this.watch();
  }

  connectedCallback() {
    this.load();
  }
  disconnectedCallback() {
    this.invalidateSelection();
  }
  /** Reloads the list only; the selected change and its review stay open. */
  @api refresh() { return this.load(); }

  async fetchPage(beforeId, generation) {
    const page = JSON.parse(await changePage({ beforeId }));
    if (generation !== this.generation) return;
    if (!Array.isArray(page.items) || page.items.length > 50 || page.items.some((row) => !row || typeof row.id !== "string" || !row.id) ||
      page.hasMore !== Boolean(page.nextCursor) || (page.nextCursor &&
      (!page.items.length || page.nextCursor === beforeId || page.nextCursor !== page.items[page.items.length - 1].id)))
      throw Error("Invalid change-history page; previous records have been kept.");
    const records = beforeId ? [...this.changes, ...page.items] : page.items;
    if (new Set(records.map((row) => row.id)).size !== records.length) throw Error("Repeated change-history record; reload to retry.");
    this.changes = records; this.cursor = page.nextCursor; this.loaded = true;
  }
  async load() {
    const generation = ++this.generation;
    try {
      await this.fetchPage(null, generation);
      if (generation === this.generation) this.error = null;
    } catch (e) {
      if (generation === this.generation) this.error = errorMessage(e);
    }
  }
  more() {
    if (!this.cursor) return;
    const generation = this.generation;
    return this.guard(() => this.fetchPage(this.cursor, generation), generation);
  }

  get rows() {
    return this.changes.map((c) => ({
      ...c,
      created: when(c.created),
      components: c.requested.map((r) => `${r.type} ${r.name}`).join(", "),
      decided: c.decidedBy ? `${c.decidedBy}, ${when(c.decidedAt)}` : "",
      className: c.id === this.selected?.id ? "atlas-selected" : "",
      statusClass: statusPill(c.status),
    }));
  }
  get selectedStatusClass() {
    return statusPill(this.selected?.status);
  }
  get resultClass() {
    const r = this.result;
    return "atlas-notice " + (!r ? "" : r.success === "true" ? "atlas-notice_success" : r.outcomeUnknown || r.done !== "true" ? "atlas-notice_warning" : "atlas-notice_error");
  }
  get hasRows() {
    return this.changes.length > 0;
  }
  get empty() {
    return this.loaded && !this.changes.length;
  }

  async guard(work, generation, epoch = this.selectionEpoch) {
    if (this.busy) return;
    const token = {};
    this.busyToken = token;
    this.busy = true;
    this.error = null;
    try {
      await work();
    } catch (e) {
      if (epoch === this.selectionEpoch && (generation === undefined || generation === this.generation)) this.error = errorMessage(e);
    } finally {
      if (this.busyToken === token) { this.busyToken = null; this.busy = false; }
    }
  }

  async select(event) {
    event.preventDefault();
    const id = event.currentTarget.dataset.id;
    const epoch = this.invalidateSelection();
    this.selected = null;
    await this.guard(async () => {
      const selected = JSON.parse(await getChange({ changeId: id }));
      if (epoch === this.selectionEpoch) this.selected = selected;
    }, undefined, epoch);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => this.template?.querySelector?.(".atlas-change-detail")?.scrollIntoView?.({ block: "start", behavior: "smooth" }));
    if (this.currentSelection(epoch, id) && this.isRunning && !this.outcomeUnknown) this.watch();
  }
  close() {
    this.invalidateSelection();
    this.selected = null;
  }

  /** Follows a running deploy or restore of the selected change until Salesforce finishes it. */
  async watch() {
    if (!this.selected || this.outcomeUnknown) return;
    const changeId = this.selected.id, epoch = this.selectionEpoch;
    if (this.watchingId === changeId) return;
    this.watchingId = changeId;
    const current = () => this.watchingId === changeId && this.currentSelection(epoch, changeId);
    try {
      // Forty minutes; the count also stops it when timers run early (tests, a throttled tab).
      const deadline = Date.now() + 2400000;
      for (let i = 0; i < 1600 && Date.now() < deadline && current(); i++) {
        const status = JSON.parse(await deployStatus({ changeId }));
        if (!current()) return;
        const r = status.result || {};
        const parts = [];
        if (Number(r.numberComponentsTotal)) parts.push(`${r.numberComponentsDeployed || 0} of ${r.numberComponentsTotal} components`);
        if (Number(r.numberTestsTotal)) parts.push(`${r.numberTestsCompleted || 0} of ${r.numberTestsTotal} tests`);
        this.progress = `${status.change.status} ${status.change.name}: ${r.status || "starting"}${parts.length ? " (" + parts.join(", ") + ")" : ""}…`;
        if (status.done) {
          const selected = JSON.parse(await getChange({ changeId }));
          if (!current()) return;
          this.cancelRestore();
          this.selected = selected;
          await this.load();
          return;
        }
        await sleep(pollDelay(i));
      }
    } catch (e) {
      if (current()) this.error = errorMessage(e);
    } finally {
      if (current()) {
        this.watchingId = null;
        this.progress = "";
      }
    }
  }

  get isRunning() {
    return RUNNING.includes(this.selected?.status);
  }
  get isProposed() {
    return this.selected?.status === "Proposed";
  }
  get canRestore() {
    return RESTORABLE.includes(this.selected?.status) && this.selected.found.length > 0 && !!this.selected.backupUrl;
  }
  get filesRemovedNote() {
    return this.selected?.filesRemoved ? `Its files were removed to free storage on ${when(this.selected.filesRemoved)}, so it cannot be restored.` : "";
  }
  // While a deploy or restore runs, the stored result is the previous run's, so show nothing.
  get result() {
    return this.isRunning && !this.outcomeUnknown ? null : this.selected?.result;
  }
  get resultLines() {
    const r = this.result;
    if (!r) return [];
    const lines = [];
    const at = (e) => `${e.file || e.type + " " + e.name}${e.line ? " line " + e.line + (e.column ? ":" + e.column : "") : ""}: ${e.problem}`;
    for (const e of r.componentErrors || []) lines.push(at(e));
    for (const w of r.componentWarnings || []) if (w.success === "true") lines.push(`Warning: ${at(w)}`);
    for (const f of r.testFailures || []) lines.push(`Test ${f.test}: ${f.message}`);
    for (const w of r.coverageWarnings || []) lines.push(`Coverage: ${w}`);
    if (r.errorMessage) lines.push(r.errorMessage);
    return lines.map((text, i) => ({ key: i, text }));
  }
  get hasResultLines() {
    return this.resultLines.length > 0;
  }
  get resultSummary() {
    const r = this.result;
    if (!r) return "";
    const what = r.operation === "restore" ? "Restore" : "Deployment";
    return `${what} ${r.outcomeUnknown ? "submission outcome unknown — verify in Setup before retrying" : r.success === "true" ? "succeeded" : r.done === "true" ? "failed" : "is running"}${r.testsRun ? ` · ${r.testsRun} test(s) ran` : ""}`;
  }
  get testOptions() {
    return TEST_LEVELS.filter((option) => option.value !== "RunSpecifiedTests");
  }
  get selectedRestoreLevel() {
    const level = this.restoreLevel || this.settings?.mine.testLevel || "Default";
    return level === "RunSpecifiedTests" ? "Default" : level;
  }


  // ---------------------------------------------------------------- history

  async loadIndex() {
    const token = (this.indexToken = {});
    try {
      const index = JSON.parse(await componentIndex());
      if (token === this.indexToken) this.componentList = index;
    } catch (e) {
      if (token === this.indexToken) this.error = errorMessage(e);
    }
  }
  get componentRows() {
    return (this.componentList?.components || []).map((c) => ({
      ...c, title: `${c.type} ${c.name}`, changed: when(c.at), className: c.key === this.historyKey ? "atlas-selected" : "",
    }));
  }
  get hasComponents() { return this.componentRows.length > 0; }
  get noComponents() { return !!this.componentList && !this.hasComponents; }
  get indexPartial() { return this.componentList?.complete === false; }

  async loadHistory(key, epoch) {
    await this.guard(async () => {
      const history = JSON.parse(await componentHistory({ component: key }));
      if (epoch === this.selectionEpoch && this.historyKey === key) this.history = history;
    }, undefined, epoch);
  }
  openHistory(event) {
    event.preventDefault();
    const key = event.currentTarget.dataset.key;
    const epoch = this.invalidateSelection();
    this.historyKey = key;
    this.history = null;
    return this.loadHistory(key, epoch);
  }
  get historyTitle() {
    return this.history ? this.history.component.replace(":", " ") : "";
  }
  get versionRows() {
    return (this.history?.versions || []).map((v) => ({
      ...v,
      key: String(v.number),
      title: `v${v.number}`,
      made: [v.kind === "Restore" ? "Restore" : "", v.change, v.by].filter(Boolean).join(" · "),
      madeAt: when(v.at),
      restoreLabel: `Restore v${v.number}`,
      canRestore: !v.current && v.restorable === true,
      className: v.current ? "atlas-selected" : "",
    }));
  }

  // ---------------------------------------------------------------- restore

  /** Restores the selected change's backup: the versions its components had before it. */
  askRestore() {
    if (this.busy || !this.canRestore) return;
    return this.openRestore(this.selected.id, null, "change");
  }
  /** Restores one version of the component whose history is open. */
  restoreVersion(event) {
    const source = event.currentTarget.dataset.source, component = this.history?.component || "";
    if (this.busy || !source || !component) return;
    return this.openRestore(source, [{ type: component.split(":")[0], name: component.slice(component.indexOf(":") + 1) }], "history");
  }
  async openRestore(sourceId, components, origin) {
    this.cancelRestore();
    const epoch = this.selectionEpoch, request = (this.restoreTarget = { pending: true });
    await this.guard(async () => {
      const plan = JSON.parse(await restorePlan({ sourceChangeId: sourceId, componentsJson: components ? JSON.stringify(components) : null }));
      if (epoch !== this.selectionEpoch || this.restoreTarget !== request) return;
      this.restoreTarget = { sourceId, components, plan, origin, epoch };
      this.activationConfirmed = false;
      this.confirmRestore = true;
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => this.template?.querySelector?.(".atlas-restore")?.scrollIntoView?.({ block: "nearest", behavior: "smooth" }));
    }, undefined, epoch);
    if (this.restoreTarget === request) this.restoreTarget = null;
  }
  cancelRestore() {
    this.restoreTarget = null;
    this.confirmRestore = false;
    this.activationConfirmed = false;
  }
  handleRestoreLevel(event) {
    this.restoreLevel = event.detail.value;
  }
  get restoreHeading() {
    const t = this.restoreTarget;
    if (t?.origin !== "history") return "Restore the backup?";
    const c = t.plan.components[0];
    return `Restore ${c.type} ${c.name} to v${c.restoreTo}?`;
  }
  get restoreActivatesFlow() { return this.restoreTarget?.plan?.activatesFlow === true; }
  /** One line per component: the version it goes back to and the versions that replaces. */
  get restoreItems() {
    return (this.restoreTarget?.plan?.components || []).map((c) => {
      const shown = c.undone.slice(-UNDONE_SHOWN).reverse().map((u) => `v${u.number} ${u.label}`);
      const more = c.undone.length - shown.length;
      return {
        key: c.key,
        title: `${c.type} ${c.name}`,
        text: c.undone.length
          ? `Back to v${c.restoreTo} (${c.label}), replacing ${shown.join("; ")}${more ? `; and ${more} earlier` : ""}.`
          : `Back to v${c.restoreTo} (${c.label}), the current version in Atlas history.`,
      };
    });
  }
  async doRestore() {
    const target = this.restoreTarget;
    if (this.busy || !this.confirmRestore || !target?.plan || target.epoch !== this.selectionEpoch ||
      (target.origin === "change" && !this.currentSelection(target.epoch, target.sourceId))) return;
    const { plan } = target, testLevel = this.selectedRestoreLevel, activationConfirmed = this.activationConfirmed;
    const expectedJson = JSON.stringify({
      revision: plan.source.revision, backupSha256: plan.source.backupSha256,
      latest: Object.fromEntries(plan.components.map((c) => [c.key, c.latestId])),
    });
    const epoch = this.invalidateSelection();
    let started;
    await this.guard(async () => {
      const result = JSON.parse(await startRestore({ sourceChangeId: target.sourceId,
        componentsJson: target.components ? JSON.stringify(target.components) : null, testLevel, activationConfirmed, expectedJson }));
      if (epoch !== this.selectionEpoch) return;
      started = result;
      this.view = "changes";
      this.selected = result;
      await this.load();
    }, undefined, epoch);
    if (started && this.currentSelection(epoch, started.id) && this.isRunning && !this.outcomeUnknown) this.watch();
  }

  // ---------------------------------------------------------------- storage

  get storageOptions() { return STORAGE_AGES; }
  toggleStorage() {
    this.storageOpen = !this.storageOpen;
    this.storage = null;
    this.storageDone = "";
    this.storageToken = null;
    if (this.storageOpen) this.checkStorage();
  }
  handleStorageDays(event) {
    this.storageDays = event.detail.value;
    this.storage = null;
    this.checkStorage();
  }
  async checkStorage() {
    const token = (this.storageToken = {}), olderThanDays = Number(this.storageDays);
    try {
      const plan = JSON.parse(await storagePlan({ olderThanDays }));
      if (token === this.storageToken) this.storage = plan;
    } catch (e) {
      if (token === this.storageToken) this.error = errorMessage(e);
    }
  }
  get storageSummary() {
    const s = this.storage;
    if (!s) return "";
    if (!s.changes) return `Nothing older than ${s.days} days can be removed.`;
    return `${s.changes} change(s) older than ${s.days} days have ${s.files} file(s), ${size(s.bytes)}. Removing them takes away ${s.restorePoints} restore point(s).`;
  }
  get storageNames() {
    const s = this.storage;
    return s?.changes ? s.names.join(", ") + (s.more ? `, and ${s.more} more` : "") : "";
  }
  get canFreeStorage() { return !!this.storage?.changes && !this.busy; }
  get freeDisabled() { return !this.canFreeStorage; }
  async freeUp() {
    const plan = this.storage;
    if (!this.canFreeStorage) return;
    const token = (this.storageToken = {});
    await this.guard(async () => {
      const done = JSON.parse(await freeStorage({ olderThanDays: plan.days, expectedJson: JSON.stringify(plan.ids) }));
      if (token !== this.storageToken) return;
      this.storage = null;
      this.storageDone = `Removed ${done.files} file(s) from ${done.changes} change(s), freeing ${size(done.bytes)}.`
        + (done.failed ? ` ${done.failed} file(s) could not be removed; they were kept.` : "");
      await this.load();
      if (this.componentList) this.loadIndex();
    });
  }
  openConversation() {
    this.dispatchEvent(new CustomEvent("openconversation", { detail: { id: this.selected.conversationId } }));
  }
}
