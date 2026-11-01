import { LightningElement, api } from "lwc";

// Copies in the click itself: the text goes into a hidden text box, is selected
// and copied before anything re-renders. The clipboard API is the fallback, and
// a select-and-copy box the last resort.
export default class AtlasCopy extends LightningElement {
  @api text = "";
  // HTML comes only from the shared, escaping email renderer, never agent HTML.
  @api html = "";
  @api label = "Copy";
  @api variant = "brand";
  copied = false;
  manual = false;

  get buttonLabel() {
    return this.copied ? "Copied" : this.label;
  }
  get icon() {
    return this.copied ? "utility:check" : "utility:copy";
  }

  handleClipboard(event) {
    if (!this.html || !event.clipboardData) return;
    try {
      event.clipboardData.setData("text/plain", this.text || "");
      event.clipboardData.setData("text/html", this.html);
      event.preventDefault();
      this.richCopied = true;
    } catch { this.richCopied = false; }
  }

  handleCopy() {
    this.richCopied = false;
    const text = this.text || "";
    const box = this.template.querySelector("textarea.atlas-copy-source");
    let ok = false;
    try {
      box.value = text;
      box.focus();
      box.select();
      box.setSelectionRange(0, text.length);
      ok = document.execCommand("copy");
    } catch {
      ok = false;
    }
    box.blur();
    if (ok && (!this.html || this.richCopied)) return this.done();
    if (this.html) {
      try {
        if (navigator.clipboard?.write && typeof ClipboardItem !== "undefined") {
          navigator.clipboard.write([new ClipboardItem({
            "text/plain": new Blob([text], {type: "text/plain"}),
            "text/html": new Blob([this.html], {type: "text/html"}),
          })]).then(() => this.done(), () => this.showManual());
          return;
        }
      } catch { /* Select-and-copy remains available. */ }
      this.showManual();
      return;
    }
    if (navigator.clipboard?.writeText)
      navigator.clipboard.writeText(text).then(
        () => this.done(),
        () => this.showManual(),
      );
    else this.showManual();
  }

  done() {
    this.copied = true;
    clearTimeout(this.timer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.timer = setTimeout(() => (this.copied = false), 1500);
    this.dispatchEvent(new CustomEvent("copied"));
  }

  showManual() {
    this.manual = true;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    requestAnimationFrame(() => {
      const box = this.template.querySelector("textarea.atlas-copy-manual");
      if (box) {
        box.value = this.text || "";
        box.focus();
        box.select();
      }
    });
  }

  handleManualCopy() {
    const box = this.template.querySelector("textarea.atlas-copy-manual");
    this.richCopied = false;
    box.select();
    if (document.execCommand("copy") && (!this.html || this.richCopied)) {
      this.manual = false;
      this.done();
    }
  }

  closeManual() {
    this.manual = false;
  }

  disconnectedCallback() {
    clearTimeout(this.timer);
  }
}
