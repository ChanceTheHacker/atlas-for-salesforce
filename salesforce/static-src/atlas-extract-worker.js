// Bundled as a classic, same-origin static-resource worker. Never load remote code.
import { extractDocument } from "../../src/files-extract.js";

self.onmessage = async ({ data }) => {
  const { id, name, bytes, mode } = data;
  try {
    const doc = await extractDocument(name, bytes);
    self.postMessage({ id, type: "progress", text: "Preparing extracted text and warnings…" });
    let result;
    if (mode === "attachment") {
      if (doc.state !== "readable") throw Error(`${name}: ${doc.notice}`);
      result = {
        kind: doc.kind,
        text: doc.sections.map((s) => `[${s.label}]\n${s.text}`).join("\n\n"),
        warnings: doc.notice ? [doc.notice] : [],
      };
    } else if (mode === "library") {
      // Serialize off-thread too, preserving the complete extraction and its limits.
      result = JSON.stringify({ ...doc, warnings: doc.notice ? [doc.notice] : [] });
      if (new TextEncoder().encode(result).length > 100 * 1024 * 1024)
        throw Error("Library JSON exceeds 100 MiB. Nothing was saved; split the data explicitly.");
    } else throw Error("Unknown document extraction mode.");
    self.postMessage({ id, type: "result", result });
  } catch (error) {
    self.postMessage({ id, type: "error", message: error.message || "Document extraction failed." });
  }
};
self.postMessage({ type: "ready" });
