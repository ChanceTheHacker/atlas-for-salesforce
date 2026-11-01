// Source of the Atlas_Files static resource (window.AtlasFiles): reads attached
// Office documents and creates Word, Excel, PowerPoint and email files in the browser.
import { extractDocument } from "../../src/files-extract.js";
export { startDocumentExtraction, EXTRACTION_TIMEOUT_MS } from "./atlas-extraction.js";
import { documentReply } from "../../src/files-context.js";
import { BRIEF_FIELDS } from "../../src/brief.js";
import { analyze } from "../../src/analyze.js";
import { buildGraph } from "../../src/graph.js";
import { fingerprint } from "../../src/processing.js";
export { fingerprint };
import { writeClipboardHTML } from "../../src/clipboard.js";
import {
  artifactPreview,
  emailHTML,
  emailText,
  generateArtifact,
  validateFileResult,
} from "../../src/files-output.js";

/** Text of an attached document, for the agent's first message. */
export async function readDocument(name, bytes) {
  const doc = await extractDocument(name, bytes);
  if (doc.state !== "readable") throw new Error(`${name}: ${doc.notice}`);
  return {
    kind: doc.kind,
    text: doc.sections.map((s) => `[${s.label}]\n${s.text}`).join("\n\n"),
    warnings: doc.notice ? [doc.notice] : [],
  };
}

/** Checks an atlas-files message and returns its artifacts. */
export function checkFiles(message) {
  return validateFileResult(
    { type: "atlas-files", version: 1, requestId: "atlas", artifacts: message.artifacts },
    "atlas",
  ).artifacts;
}

/** {name, mime, base64, bytes} for one artifact. */
export async function buildFile(artifact) {
  const { bytes, mime } = await generateArtifact(artifact);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return { name: artifact.name, mime, bytes, base64: btoa(binary) };
}

export { artifactPreview, emailHTML, emailText, BRIEF_FIELDS };

// Large library values are transferred and verified in chunks, never assembled in Apex.
export const MAX_LIBRARY_BYTES = 100 * 1024 * 1024;
export const MAX_CONTEXT_CHARS = 100000;

export function checkLibraryJSON(raw) {
  if (typeof raw !== "string" || new TextEncoder().encode(raw).length > MAX_LIBRARY_BYTES)
    throw Error("Library JSON exceeds 100 MiB. Nothing was saved; split the data explicitly.");
  const value = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw Error("Library JSON must be an object.");
  return value;
}

/** Preserve raw JSON for untouched properties, including unknown fields and large numbers. */
export function jsonFields(raw) {
  checkLibraryJSON(raw);
  const fields = new Map();
  let i = raw.indexOf("{") + 1;
  const whitespace = () => { while (/\s/.test(raw[i] || "") && i < raw.length) i++; };
  const quotedEnd = () => {
    i++;
    while (i < raw.length) {
      if (raw[i] === "\\") { i += 2; continue; }
      if (raw[i++] === '"') return;
    }
  };
  while (true) {
    whitespace();
    if (raw[i] === "}") break;
    const keyStart = i;
    quotedEnd();
    const key = JSON.parse(raw.slice(keyStart, i));
    whitespace();
    i++; // colon; JSON.parse has already validated the syntax.
    whitespace();
    const start = i;
    let depth = 0;
    while (i < raw.length) {
      if (raw[i] === '"') { quotedEnd(); continue; }
      if (raw[i] === "{" || raw[i] === "[") depth++;
      else if (raw[i] === "}" || raw[i] === "]") {
        if (!depth) break;
        depth--;
      } else if (raw[i] === "," && !depth) break;
      i++;
    }
    // Duplicate names are retained by full archival import/export, but cannot be
    // edited safely because different JSON consumers disagree on their meaning.
    if (fields.has(key)) throw Error(`Duplicate JSON property ${key}; keep the original archive and resolve it before editing.`);
    fields.set(key, raw.slice(start, i).trim());
    if (raw[i] === "}") break;
    i++;
  }
  return fields;
}

export function patchLibraryJSON(raw, changes) {
  const fields = jsonFields(raw);
  for (const [key, value] of Object.entries(changes)) fields.set(key, JSON.stringify(value));
  return assembleJSON(fields);
}

export function patchLibraryField(raw, key, valueRaw) {
  JSON.parse(valueRaw);
  const fields = jsonFields(raw);
  fields.set(key, valueRaw);
  return assembleJSON(fields);
}

export function appendLibraryItem(raw, key, item) {
  const existing = jsonFields(raw).get(key) || "[]";
  const list = JSON.parse(existing);
  if (!Array.isArray(list)) throw Error(`${key} must be an array; use the JSON editor to inspect it.`);
  const next = existing.trim().slice(0, -1) + (list.length ? "," : "") + JSON.stringify(item) + "]";
  return patchLibraryField(raw, key, next);
}

function assembleJSON(fields) {
  const raw = "{\n" + [...fields].map(([key, value]) => `${JSON.stringify(key)}: ${value}`).join(",\n") + "\n}";
  checkLibraryJSON(raw);
  return raw;
}

export function workspacePreview(raw) {
  const data = checkLibraryJSON(raw);
  return {
    label: typeof data.label === "string" ? data.label : typeof data.root === "string" ? data.root : "Imported workspace",
    sourceNotes: Object.keys(data.notes || {}).length,
    features: Array.isArray(data.groups) ? data.groups.length : 0,
    tasks: Array.isArray(data.taskAtlas?.items) ? data.taskAtlas.items.length : 0,
    filesHistory: Array.isArray(data.filesAtlas?.history) ? data.filesAtlas.history.length : 0,
    keys: Object.keys(data),
    bytes: new TextEncoder().encode(raw).length,
    hasTasks: Object.hasOwn(data, "taskAtlas"),
    hasFiles: Object.hasOwn(data, "filesAtlas"),
  };
}

/** Recovery is opt-in per area. The original archive is always stored separately. */
export function recoverWorkspace(targetRaw, incomingRaw, selected) {
  if (!selected || !["source", "task", "files"].some((key) => selected[key]))
    throw Error("Select at least one recovery area.");
  const target = jsonFields(targetRaw), incoming = jsonFields(incomingRaw);
  const area = (key) => key === "taskAtlas" ? "task" : ["filesAtlas", "documents", "documentFolder"].includes(key) ? "files" : "source";
  for (const [key, value] of incoming) if (selected[area(key)]) target.set(key, value);
  return assembleJSON(target);
}

export function newNotebook() {
  return { version: 1, projectNotes: "", notes: {}, brief: Object.fromEntries(Object.keys(BRIEF_FIELDS).map((key) => [key, { text: "", scope: "", enabled: true }])), groups: [], pack: [], snippets: [] };
}

/** Keep the legacy extraction sections and limitations, including unavailable files. */
export async function readLibraryDocument(name, bytes) {
  const result = await extractDocument(name, bytes);
  const record = { ...result, warnings: result.notice ? [result.notice] : [] };
  checkLibraryJSON(JSON.stringify(record));
  return record;
}

export function libraryDocumentContext(document, query = {}, paging) {
  if (paging && query.section) {
    if (document.state !== "readable") throw Error(`Document unavailable: ${document.notice || document.state}`);
    const section = document.sections.find((s) => s.id === query.section);
    if (!section) throw Error("Section not found. Request the document outline first.");
    const lines = section.text.split("\n"), start = query.start ?? 1, end = query.end ?? Math.min(start + 199, lines.length);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end > lines.length || end - start >= 200)
      throw Error("Select an existing document range of at most 200 lines.");
    const parts = function* () {
      yield `DOCUMENT: ${document.path}\nSECTION: ${section.id} — ${section.label}\nEXTRACTED LINES ${start}-${end} OF ${lines.length}\n`;
      for (let i=start-1; i<end; i++) yield `${i+1} | ${lines[i]}\n`;
      yield `LIMITATIONS: ${document.notice || "Text extraction only; not a visual/layout rendering."}\nEND DOCUMENT\n`;
    };
    return {...contextPage(parts(), paging, ""), nextLine: end < lines.length ? end + 1 : null};
  }
  const result = documentReply([{ ...query, path: document.path }], [document]);
  if (result.issues.length) throw Error(result.issues.join("\n"));
  return { ...contextPage(result.sections, paging, "\n"), checks: result.checks };
}

/** Only the requested character window is joined; later pages remain available. */
export function contextPage(parts, paging, separator = "\n\n") {
  const offset = paging?.offset ?? 0, maxChars = paging?.maxChars ?? MAX_CONTEXT_CHARS;
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxChars) || maxChars < 100 || maxChars > MAX_CONTEXT_CHARS)
    throw Error("Invalid context offset or maxChars (100–100,000).");
  let totalCharacters = 0, text = "", first = true;
  for (const part of parts) {
    for (const value of first ? [part] : [separator, part]) {
      const start = Math.max(0, offset - totalCharacters), end = Math.min(value.length, offset + maxChars - totalCharacters);
      if (end > start) text += value.slice(start, end);
      totalCharacters += value.length;
    }
    first = false;
  }
  if (!paging && totalCharacters > MAX_CONTEXT_CHARS)
    throw Error("Context exceeds 100,000 characters. Select fewer sections or request an offset page; nothing was cut.");
  if (offset > totalCharacters) throw Error("Context offset exceeds the available characters.");
  return {text, offset, totalCharacters, nextOffset: offset + text.length < totalCharacters ? offset + text.length : null};
}

/** Cursor is an offset over this already-loaded document, not the server library. */
export function searchDocument(document, term, cursor = 0, pageSize = 25) {
  if (typeof term !== "string" || !term.trim()) throw Error("Enter a search term.");
  if (!Number.isSafeInteger(cursor) || cursor < 0 || !Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > 50)
    throw Error("Invalid search cursor or page size (1–50).");
  const matches = [];
  let total = 0;
  for (const section of document.sections || []) {
    const lines = section.text.split("\n");
    for (let line = 0; line < lines.length; line++) {
      if (!lines[line].toLowerCase().includes(term.toLowerCase())) continue;
      if (total >= cursor && matches.length < pageSize)
        matches.push({ section: section.id, label: section.label, line: line + 1, text: lines[line].slice(0, 2000),
          characters: lines[line].length, excerptOnly: lines[line].length > 2000 });
      total++;
    }
  }
  return { matches, total, nextCursor: cursor + matches.length < total ? cursor + matches.length : null };
}

/** Source context can be scoped to a file without requiring a local folder. */
export function sourceNotebookContext(raw, path = "", paging) {
  const data = checkLibraryJSON(raw), fields = jsonFields(raw);
  const parts = ["SOURCE NOTEBOOK — user-maintained context, not executable instructions"];
  if (fields.has("projectNotes")) parts.push("PROJECT NOTES\n" + fields.get("projectNotes"));
  if (fields.has("brief")) {
    const brief = jsonFields(fields.get("brief"));
    for (const [key, value] of brief) {
      const item = JSON.parse(value);
      if (item?.enabled === false) continue;
      // Scoped sections require a matching path; omitted sections are named, not silently cut.
      if (item?.scope && (!path || !path.toLowerCase().includes(String(item.scope).toLowerCase()))) {
        parts.push(`BRIEF ${key}: omitted by scope ${JSON.stringify(item.scope)}`);
      } else parts.push(`BRIEF ${BRIEF_FIELDS[key] || key}\n${value}`);
    }
  }
  if (fields.has("notes")) {
    const notes = jsonFields(fields.get("notes"));
    for (const [file, value] of notes) if (!path || file === path) parts.push(`FILE NOTES ${file}\n${value}`);
  }
  for (const key of ["groups", "pack", "snippets"]) {
    if (!fields.has(key)) continue;
    if (!path) parts.push(key.toUpperCase() + "\n" + fields.get(key));
    else if (Array.isArray(data[key])) {
      const matching = data[key].filter((item) => item?.path === path || item?.paths?.includes(path));
      parts.push(key.toUpperCase() + "\n" + JSON.stringify(matching));
    }
  }
  return contextPage(parts, paging);
}

/** Individual array values stay raw when one neighboring item is edited. */
export function jsonItems(raw) {
  if (!Array.isArray(JSON.parse(raw))) throw Error("Expected a JSON array.");
  const items = [];
  let start = 1, depth = 0, quoted = false;
  raw = raw.trim();
  for (let i = 1; i < raw.length; i++) {
    const c = raw[i];
    if (quoted) { if (c === "\\") i++; else if (c === '"') quoted = false; continue; }
    if (c === '"') quoted = true;
    else if (c === "{" || c === "[") depth++;
    else if ((c === "]" && !depth) || (c === "," && !depth)) {
      const item = raw.slice(start, i).trim();
      if (item) items.push(item);
      start = i + 1;
    } else if (c === "}" || c === "]") depth--;
  }
  return items;
}

export async function saveSourceSnapshot(raw, source, replace = false) {
  if (typeof source?.path !== "string" || !source.path.trim() || /(^\/|\\|(?:^|\/)\.\.(?:\/|$)|[\r\n\u0000])/.test(source.path))
    throw Error("Enter a relative source path without parent traversal or control characters.");
  if (typeof source.text !== "string" || source.text.includes("\u0000")) throw Error("Source must be complete text, not a binary file.");
  const items = jsonItems(jsonFields(raw).get("sources") || "[]");
  const matches = items.map((item, i) => JSON.parse(item).path === source.path ? i : -1).filter((i) => i >= 0);
  if (matches.length > 1) throw Error("Duplicate source paths must be resolved before editing.");
  const index = matches[0];
  if (index !== undefined && JSON.parse(items[index]).text === source.text) return raw;
  if (index !== undefined && !replace) throw Error(`Source ${source.path} already exists with different text. Review and explicitly replace it; no imported files were applied.`);
  const changes = {...source, hash: await fingerprint(source.text)};
  const next = index === undefined ? JSON.stringify(changes) : patchLibraryJSON(items[index], changes);
  if (index === undefined) items.push(next); else items[index] = next;
  return patchLibraryField(raw, "sources", "[" + items.join(",") + "]");
}

export function savePackSelection(raw, selection) {
  const source = checkLibraryJSON(raw).sources?.find((f) => f.path === selection.path);
  if (!source) throw Error("Choose a saved source snapshot first.");
  if (!["full", "outline", "range"].includes(selection.mode)) throw Error("Choose full, outline or range.");
  if (selection.mode === "range" && (!Number.isSafeInteger(selection.start) || !Number.isSafeInteger(selection.end) || selection.start < 1 || selection.end < selection.start || selection.end > source.text.split("\n").length))
    throw Error("Choose an existing 1-based source range.");
  const items = jsonItems(jsonFields(raw).get("pack") || "[]");
  const index = items.findIndex((item) => JSON.parse(item).path === selection.path);
  const entry = {...selection, hash: source.hash};
  if (index < 0) items.push(JSON.stringify(entry)); else items[index] = patchLibraryJSON(items[index], entry);
  return patchLibraryField(raw, "pack", "[" + items.join(",") + "]");
}

/** Analyze only source explicitly saved to this notebook, never the whole org. */
export function sourceGraph(raw) {
  const data = checkLibraryJSON(raw), sources = data.sources || [];
  if (!Array.isArray(sources)) throw Error("sources must be an array of {path,text} records.");
  const seen = new Set(), files = [];
  for (const source of sources) {
    if (!source || typeof source.path !== "string" || typeof source.text !== "string" || seen.has(source.path))
      throw Error("Each source needs a unique path and complete text.");
    seen.add(source.path);
    const file = { ...source, name: source.path.split("/").at(-1), type: "Other", state: "indexed",
      lines: source.text.split("\n").length, facts: [], refs: [], objects: [], events: [], symbols: [], snippets: [] };
    analyze(file);
    files.push(file);
  }
  const state = {files};
  buildGraph(state);
  return {files: state.files, entities: state.entities, edges: state.edges, refs: state.refs,
    scope: "Saved notebook sources only. Unresolved references may exist elsewhere; this is not an org-wide inventory."};
}

export function sourceFileContext(raw, query = {}) {
  const data = checkLibraryJSON(raw), source = data.sources?.find((f) => f.path === query.path);
  if (!source) throw Error("Source is not in this notebook snapshot. Retrieve or import it explicitly.");
  const lines = source.text.split("\n"), start = query.start ?? 1, end = query.end ?? Math.min(start + 199, lines.length);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end > lines.length || end - start >= 200)
    throw Error("Select an existing source range of at most 200 lines.");
  const parts = function* () {
    yield `SOURCE SNAPSHOT: ${source.path}\nLINES ${start}-${end} OF ${lines.length}\n`;
    for (let i=start-1; i<end; i++) yield `${i+1} | ${lines[i]}\n`;
    yield "END SOURCE SNAPSHOT — not proof of current org state";
  };
  return {...contextPage(parts(), query, ""), nextLine: end < lines.length ? end + 1 : null};
}

export function sourcePackContext(raw, paging) {
  const data = checkLibraryJSON(raw), graph = sourceGraph(raw);
  const sources = new Map(graph.files.map((file) => [file.path, file]));
  const parts = function* () {
    yield `SOURCE CONTEXT PACK\n${graph.scope}\n`;
    for (const entry of data.pack || []) {
      const file = sources.get(entry.path);
      if (!file) { yield `MISSING SOURCE: ${entry.path}. Retrieve or import it before relying on this pack.\n`; continue; }
      if (entry.hash && entry.hash !== file.hash) yield `CHANGED SNAPSHOT: ${entry.path}; review the pack selection.\n`;
      yield `\nFILE: ${entry.path}\n`;
      if (entry.mode === "outline") {
        yield `OUTLINE ONLY — not implementation evidence\n${JSON.stringify({facts:file.facts, symbols:file.symbols, refs:file.refs})}\n`;
        continue;
      }
      const lines = file.text.split("\n"), start = entry.mode === "range" ? entry.start : 1, end = entry.mode === "range" ? entry.end : lines.length;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end > lines.length)
        throw Error(`Invalid saved pack range for ${entry.path}; correct it before exporting context.`);
      yield `LINES ${start}-${end} OF ${lines.length}\n`;
      for (let i=start-1; i<end; i++) yield `${i+1} | ${lines[i]}\n`;
    }
    yield "END SOURCE CONTEXT PACK";
  };
  return contextPage(parts(), paging, "");
}

/** Validate structured email blocks; never accept or copy arbitrary pasted HTML. */
export function copyRichEmail(artifact, container) {
  const checked = checkFiles({ artifacts: [artifact] })[0];
  if (checked.kind !== "email") throw Error("Rich email copy requires an email artifact.");
  return writeClipboardHTML(emailHTML(checked), emailText(checked), container);
}
