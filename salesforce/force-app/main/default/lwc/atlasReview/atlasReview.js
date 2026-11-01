import { LightningElement, api } from "lwc";
import { TEST_LEVELS, lineDiff } from "c/atlasLib";

export default class AtlasReview extends LightningElement {
  @api boot;
  @api testLevel = "Default";
  @api busy = false;
  /** Shows the change without the approve and reject controls. */
  @api readOnly = false;
  note = "";
  level;
  files = [];
  _change;
  activationConfirmed = false;
  recoveryStatus = "";
  connected = false;
  get recoveryKey() {
    return this.boot?.org?.id && this.boot?.user?.id && this._change?.id
      ? `atlas-review:${this.boot.org.id}:${this.boot.user.id}:${this._change.id}:${this._change.revision}` : null;
  }
  connectedCallback() { this.connected = true; this.restoreNote(); }
  disconnectedCallback() { this.connected = false; }
  restoreNote() {
    this.note = ""; this.level = undefined; this.activationConfirmed = false;
    if (!this.recoveryKey || this.readOnly) return;
    try {
      const saved = JSON.parse(sessionStorage.getItem(this.recoveryKey) || "null");
      if (saved && typeof saved.note === "string") {
        this.note = saved.note;
        this.level = TEST_LEVELS.some((option) => option.value === saved.level) ? saved.level : undefined;
        this.recoveryStatus = "Review note recovered from this tab. Approval and Flow activation are never restored automatically.";
      }
    } catch { this.recoveryStatus = "Browser note recovery is unavailable. Keep your review note separately before leaving."; }
  }
  cacheNote() {
    if (!this.connected || !this.recoveryKey || this.readOnly) return;
    try {
      sessionStorage.setItem(this.recoveryKey, JSON.stringify({ note: this.note, level: this.selectedLevel }));
      this.recoveryStatus = "Review note saved in this browser tab. Nothing has been approved.";
    } catch { this.recoveryStatus = "Review note NOT saved. Keep a copy before leaving this tab."; }
  }

  @api
  get change() {
    return this._change;
  }
  set change(value) {
    const changed = value?.id !== this._change?.id || value?.revision !== this._change?.revision;
    if (changed) this.activationConfirmed = false;
    this._change = value;
    if (changed && this.connected) this.restoreNote();
    this.files = value?.proposal ? this.buildFiles(value) : [];
  }

  buildFiles(change) {
    return (change.proposal.files || []).map((f, i) => {
      const before = change.before?.[f.path];
      const binary = before === "[binary file]";
      const diff = binary ? { rows: [], added: 0, removed: 0 } : lineDiff(before, f.content);
      const comments = new Map();
      for (const c of f.comments || []) {
        const line = Number(c.line);
        comments.set(line, [...(comments.get(line) || []), c.text]);
      }
      const shown = new Set();
      const rows = diff.rows.map((r) => {
        const notes = r.type !== "del" && r.newLine ? comments.get(r.newLine) : null;
        if (notes) shown.add(r.newLine);
        return {
          ...r,
          className: "atlas-line atlas-line_" + r.type,
          sign: r.type === "add" ? "+" : r.type === "del" ? "−" : "",
          comment: notes ? notes.join(" · ") : "",
        };
      });
      const otherComments = [...comments.entries()]
        .filter(([line]) => !shown.has(line))
        .map(([line, texts]) => ({ key: line, text: `Line ${line || "?"}: ${texts.join(" · ")}` }));
      return {
        key: f.path + i,
        path: f.path,
        reason: f.reason,
        isNew: before === undefined,
        binary,
        stats: binary ? "binary file" : `+${diff.added} −${diff.removed}`,
        unchanged: !binary && diff.added === 0 && diff.removed === 0,
        rows,
        otherComments,
        hasOtherComments: otherComments.length > 0,
      };
    });
  }

  get proposal() {
    return this._change?.proposal || {};
  }
  get title() {
    return this.proposal.summary || this._change?.summary || this._change?.name || "Proposed change";
  }
  get reasoning() {
    return this.proposal.reasoning || "The agent did not give a reason.";
  }
  get tests() {
    return (this.proposal.tests || []).join(", ");
  }
  get canDecide() {
    return !this.readOnly && this._change?.status === "Proposed";
  }
  get testOptions() {
    return TEST_LEVELS;
  }
  get selectedLevel() {
    return this.level || this.testLevel || "Default";
  }
  get statusClass() {
    const status = this._change?.status || "";
    return "atlas-pill " + (status === "Proposed" ? "atlas-pill_warning" : /Deployed|Restored/.test(status) ? "atlas-pill_success" : /Fail|Reject/.test(status) ? "atlas-pill_danger" : "");
  }
  get fileCount() {
    const n = this.files.length;
    return `${n} file${n === 1 ? "" : "s"}`;
  }
  get backupLabel() {
    return `Download backup ZIP (${this._change.name})`;
  }

  handleNote(event) {
    this.note = event.detail.value;
    this.noteError = false;
    this.cacheNote();
  }
  handleLevel(event) {
    this.level = event.detail.value;
    this.cacheNote();
  }
  get activatesFlow() {
    return this._change?.activatesFlow === true;
  }
  get approvalDisabled() { return this.busy || (this.activatesFlow && !this.activationConfirmed); }
  handleActivation(event) { this.activationConfirmed = event.target.checked; }
  approve() {
    if (!this.approvalDisabled) this.decide(true);
  }
  reject() {
    if (!this.note.trim()) {
      this.template.querySelector("lightning-textarea").reportValidity();
      this.noteError = true;
      return;
    }
    this.decide(false);
  }
  noteError = false;
  decide(approve) {
    this.dispatchEvent(
      new CustomEvent("decide", {
        detail: { approve, note: this.note.trim(), testLevel: this.selectedLevel, activationConfirmed: this.activationConfirmed },
      }),
    );
  }
}
