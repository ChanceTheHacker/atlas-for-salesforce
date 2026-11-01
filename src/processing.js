import { analyze } from "./analyze.js";
import { buildGraph } from "./graph.js";
export async function fingerprint(text) {
  if (globalThis.crypto?.subtle) {
    const buffer = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(text),
    );
    return Array.from(new Uint8Array(buffer), (v) =>
      v.toString(16).padStart(2, "0"),
    ).join("");
  }
  let a = 2166136261,
    b = 5381;
  for (let i = 0; i < text.length; i++) {
    a = Math.imul(a ^ text.charCodeAt(i), 16777619);
    b = Math.imul(b, 33) ^ text.charCodeAt(i);
  }
  return `${text.length}:${a >>> 0}:${b >>> 0}`;
}
export async function processJob(job) {
  if (job.kind === "graph") {
    const state = { files: job.files };
    buildGraph(state);
    return state;
  }
  const f = job.file;
  if (f.state === "indexed") {
    try {
      f.text = await job.blob.text();
      if (f.text.includes("\u0000")) {
        f.text = "";
        f.state = "binary";
      }
    } catch {
      f.text = "";
      f.state = "unreadable";
    }
  }
  f.lines = f.state === "indexed" ? f.text.split("\n").length : 0;
  f.hash =
    f.state === "indexed"
      ? await fingerprint(f.text)
      : `meta:${f.size}:${f.modified}`;
  if (f.state === "indexed") analyze(f);
  return f;
}
