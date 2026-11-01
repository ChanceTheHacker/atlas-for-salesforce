import loadEntry from "@salesforce/apex/Atlas_Library.loadEntry";
import loadVersion from "@salesforce/apex/Atlas_Library.loadVersion";
import saveEntry from "@salesforce/apex/Atlas_Library.saveEntry";
import beginUpload from "@salesforce/apex/Atlas_Library.beginUpload";
import writePart from "@salesforce/apex/Atlas_Library.writePart";
import commitUpload from "@salesforce/apex/Atlas_Library.commitUpload";
import readPart from "@salesforce/apex/Atlas_Library.readPart";
import reserveRecovery from "@salesforce/apex/Atlas_Library.reserveRecovery";

const parse = (value) => typeof value === "string" ? JSON.parse(value) : value;
export const ARCHIVE_LIMIT = 100 * 1024 * 1024;

/**
 * Runs work(item, index) for every item, at most `limit` at a time, and returns the results in
 * item order. Independent server reads used to wait for each other one by one. After the first
 * failure no further work starts and the failure is thrown.
 */
export async function inOrder(items, limit, work) {
  const results = new Array(items.length);
  let next = 0, failed = false;
  const lane = async () => {
    while (next < items.length && !failed) {
      const index = next++;
      try { results[index] = await work(items[index], index); } catch (e) { failed = true; throw e; }
    }
  };
  await Promise.all(Array.from({length: Math.min(limit, items.length)}, lane));
  return results;
}

// readLibrary parses every entry to check it; libraryData reuses that parse instead of reading a large archive twice.
const parsedRows = new WeakMap();
export const libraryData = (row) => parsedRows.has(row) ? parsedRows.get(row) : JSON.parse(row.dataJson);

export function archiveChunks(text) {
  const chunks = [];
  for (let offset = 0; offset < text.length;) {
    let end = Math.min(offset + 190000, text.length);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end--;
    chunks.push(text.slice(offset, end));
    offset = end;
  }
  return chunks;
}

export async function readLibrary(args) {
  const row = parse(await (args.versionId ? loadVersion(args) : loadEntry(args)));
  const manifest = JSON.parse(row.dataJson);
  if (manifest?.type !== "atlas-chunked") { parsedRows.set(row, manifest); return row; }
  if (!manifest.parts || !Number.isInteger(manifest.count) || manifest.count < 1 || manifest.count > 600 ||
      !Number.isInteger(manifest.bytes) || manifest.bytes < 2 || manifest.bytes > ARCHIVE_LIMIT ||
      !Number.isInteger(manifest.chars) || manifest.chars < 2 || manifest.chars > manifest.bytes)
    throw Error("Invalid archive manifest. Nothing was imported.");
  const indexes = Array.from({length: manifest.count}, (_, index) => index);
  if (indexes.some((index) => !manifest.parts[index])) throw Error("Archive is missing a chunk. Nothing was imported.");
  // Chunks are read four at a time; each is checked as it arrives and they are joined in order.
  const parts = await inOrder(indexes, 4, async (index) => {
    const text = await readPart({recordId: row.id, versionId: row.loadedVersionId || row.versionId, index});
    if (typeof text !== "string" || text.length !== manifest.parts[index].chars) throw Error("Archive chunk length verification failed.");
    return text;
  });
  const dataJson = parts.join("");
  if (dataJson.length !== manifest.chars || new TextEncoder().encode(dataJson).length !== manifest.bytes)
    throw Error("Archive size verification failed. Nothing was imported.");
  const read = {...row, dataJson};
  parsedRows.set(read, JSON.parse(dataJson));
  return read;
}

export function newLibraryIdentity() {
  return globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
}

export async function restoreLibrary(args, recoveryKey, progress) {
  const reserved = parse(await reserveRecovery({recoveryKey, title: args.title, kind: args.kind}));
  // Small bodies go through the optimistic replay check even if already saved:
  // a reused identity must not silently swallow a different title or payload.
  if (reserved.versionId && new TextEncoder().encode(args.dataJson).length > 1000000) return reserved;
  return writeLibrary({...args, recordId: reserved.id, expectedRevision: 0}, progress);
}

const uploads = new Map();
async function uploadKey(args) {
  const raw = JSON.stringify(args);
  if (!globalThis.crypto?.subtle) return raw;
  const hash = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  return "atlas-upload:" + Array.from(new Uint8Array(hash), (n) => n.toString(16).padStart(2, "0")).join("");
}
function remember(key, upload) {
  uploads.set(key, upload);
  // Never put workspace content into browser storage; only a digest and upload receipt.
  if (key.startsWith("atlas-upload:")) try { sessionStorage.setItem(key, JSON.stringify(upload)); } catch { /* In-memory retries still work. */ }
}

export async function writeLibrary(args, progress = () => {}) {
  const text = args.dataJson;
  const bytes = new TextEncoder().encode(text).length;
  if (bytes > ARCHIVE_LIMIT) throw Error("Workspace exceeds 100 MiB. No existing data was changed.");
  const data = JSON.parse(text);
  if (!data || typeof data !== "object" || Array.isArray(data)) throw Error("Library JSON must be an object.");
  const {creationKey, ...request} = args;
  if (bytes <= 1000000) {
    if (!request.recordId) {
      if (typeof creationKey !== "string" || !creationKey || creationKey.length > 190 || request.expectedRevision !== 0)
        throw Error("A new library entry needs a saved creation identity and revision 0 before saving. Keep the draft and retry.");
      const reserved = parse(await reserveRecovery({recoveryKey: "create:" + creationKey, title: request.title, kind: request.kind}));
      request.recordId = reserved.id;
    }
    return parse(await saveEntry(request));
  }
  const parts = archiveChunks(text), key = await uploadKey(request);
  let upload = uploads.get(key);
  if (!upload && key.startsWith("atlas-upload:")) try { upload = JSON.parse(sessionStorage.getItem(key) || "null"); } catch { /* No browser receipt available. */ }
  if (!upload) {
    const uploadId = await beginUpload({recordId: args.recordId, title: args.title, kind: args.kind,
      expectedRevision: args.expectedRevision, chars: text.length, bytes, count: parts.length});
    upload = {uploadId, next: 0};
    remember(key, upload);
  }
  for (let index = upload.next; index < parts.length; index++) {
    await writePart({uploadId: upload.uploadId, index, text: parts[index]});
    upload.next = index + 1;
    remember(key, upload);
    progress(`Saved ${index + 1} of ${parts.length} archive chunks; existing library unchanged until verified commit.`);
  }
  const saved = parse(await commitUpload({uploadId: upload.uploadId}));
  uploads.delete(key);
  if (key.startsWith("atlas-upload:")) try { sessionStorage.removeItem(key); } catch { /* Replaying a committed upload is safe. */ }
  return saved;
}
