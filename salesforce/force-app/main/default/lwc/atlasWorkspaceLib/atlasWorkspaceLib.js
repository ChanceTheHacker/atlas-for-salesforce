import beginExport from "@salesforce/apex/Atlas_Workspace.beginExport";
import recordPage from "@salesforce/apex/Atlas_Workspace.recordPage";
import recordBody from "@salesforce/apex/Atlas_Workspace.recordBody";
import linkPage from "@salesforce/apex/Atlas_Workspace.linkPage";
import versionPage from "@salesforce/apex/Atlas_Workspace.versionPage";
import fileBody from "@salesforce/apex/Atlas_Workspace.fileBody";
import historyPage from "@salesforce/apex/Atlas_Workspace.historyPage";
import prepareRecord from "@salesforce/apex/Atlas_WorkspaceRecovery.prepareRecord";
import stageFile from "@salesforce/apex/Atlas_WorkspaceRecovery.stageFile";
import reviewRecord from "@salesforce/apex/Atlas_WorkspaceRecovery.reviewRecord";
import applyRecord from "@salesforce/apex/Atlas_WorkspaceRecovery.applyRecord";
import { restoreLibrary, readLibrary, inOrder } from "c/atlasStorage";

export const FORMAT = "atlas-native-workspace";
export const ARCHIVE_LIMIT = 100 * 1024 * 1024;
export const FILE_LIMIT = 1500000;
export const TYPES = ["Conversation", "Message", "Ticket", "Person", "Setting", "Change", "Library"].map((name) => `Atlas_${name}__c`);
const PARALLEL_READS = 4;
const FILE_FIELDS = ["Request_File__c", "State_File__c", "Body_File__c", "Raw_File__c", "Export_File__c", "Data_File__c", "Backup_File__c", "Proposal_File__c"];
const parse = (value) => typeof value === "string" ? JSON.parse(value) : value;
const size = (text) => new TextEncoder().encode(text).length;
export const errorText = (error) => error?.body?.message || error?.message || String(error);
const require = (ok, message) => { if (!ok) throw Error(message); };
const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const api = { beginExport, recordPage, recordBody, linkPage, versionPage, fileBody, historyPage, prepareRecord, stageFile, reviewRecord, applyRecord };

export async function digest(bytes) {
  require(globalThis.crypto?.subtle, "Secure SHA-256 is unavailable. Nothing will be imported without integrity verification.");
  const hash = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (n) => n.toString(16).padStart(2, "0")).join("");
}
export function fileBytes(file) {
  require(typeof file.base64 === "string" && file.base64.length <= 2000000 && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(file.base64), "Invalid or oversized File encoding.");
  const raw = atob(file.base64);
  require(Number.isSafeInteger(file.bytes) && file.bytes >= 0 && file.bytes <= FILE_LIMIT && raw.length === file.bytes, "File byte count does not match its manifest.");
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
export function chunkManifest(file) {
  let value;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(fileBytes(file))); }
  catch { return null; }
  if (value?.type !== "atlas-chunked") return null;
  require(isObject(value.parts) && Object.keys(value.parts).length <= 600 && Number.isSafeInteger(value.count) && value.count > 0 && value.count <= 600,
    "Invalid chunk manifest; no partial library will be recovered.");
  // Pending upload manifests can contain fewer parts. Preserve them as history, never resume the upload.
  for (const part of Object.values(value.parts)) require(isObject(part) && typeof part.id === "string" && /^[a-f0-9]{64}$/.test(part.sha256), "Invalid chunk reference.");
  return value;
}
export function referencedFiles(record) {
  const ids = FILE_FIELDS.map((field) => record.values[field]).filter(Boolean);
  if (record.type === "Atlas_Change__c" && record.values.Result__c) {
    try { const result = JSON.parse(record.values.Result__c); if (typeof result?.fileId === "string") ids.push(result.fileId); }
    catch { /* Malformed historical JSON is preserved exactly, not repaired. */ }
  }
  return [...new Set(ids)];
}

/** Every page is bounded, exclusive and explicitly terminal. Repeating/lying cursors fail closed. */
export async function walkPages(call, args, accept, cancelled = () => false) {
  let cursor = null;
  const cursors = new Set(), ids = new Set();
  do {
    require(!cancelled(), "Export cancelled; no complete backup was produced.");
    const page = parse(await call({ ...args, cursor }));
    require(Array.isArray(page?.items) && page.items.length <= 50 && typeof page.hasMore === "boolean", "Invalid bounded page response.");
    require(page.hasMore === Boolean(page.nextCursor) && (!page.hasMore || page.items.length > 0), "Paging completeness cannot be established.");
    for (const item of page.items) {
      const id = item.Id || item.id;
      require(typeof id === "string" && !ids.has(id), "Duplicate keyset row; completeness cannot be established.");
      ids.add(id);
      await accept(item);
    }
    cursor = page.nextCursor;
    require(!cursor || !cursors.has(cursor), "Repeated keyset cursor; completeness cannot be established.");
    if (cursor) cursors.add(cursor);
  } while (cursor);
  return ids;
}

/** Browser assembly is bounded at 100 MiB; Apex never assembles the workspace. */
export async function exportWorkspace(progress = () => {}, cancelled = () => false, boundary = api) {
  const start = parse(await boundary.beginExport());
  const archive = { type: FORMAT, version: 1, scope: start.scope, schemas: start.schemas, records: [], files: [],
    startedAt: new Date().toISOString(), completeness: { complete: false, issues: [] } };
  const files = new Map(), documents = new Set(), inventories = new Map();
  let bytes = size(JSON.stringify(archive));
  const account = (value) => { bytes += size(JSON.stringify(value)) + 1; require(bytes <= ARCHIVE_LIMIT, "Workspace exceeds 100 MiB. No truncated backup was produced; export smaller native scopes is not implemented."); };
  const issue = (scope, id, error) => {
    const item = { scope, id, message: errorText(error) };
    account(item); archive.completeness.issues.push(item);
  };
  const safe = async (scope, id, work) => {
    try { await work(); }
    catch (error) {
      if (cancelled() || /exceeds 100 MiB/.test(errorText(error))) throw error;
      issue(scope, id, error);
    }
  };
  const loadDocument = async (documentId) => {
    if (documents.has(documentId)) return;
    documents.add(documentId);
    await safe("document", documentId, () => walkPages(boundary.versionPage, { documentId, cutoff: start.scope.cutoff },
      (row) => loadFile(row.Id || row.id), cancelled));
  };
  const loadFile = async (id) => {
    if (files.has(id)) return;
    files.set(id, null);
    await safe("file", id, async () => {
      require(!cancelled(), "Export cancelled.");
      const file = parse(await boundary.fileBody({ versionId: id }));
      require(file.id === id && await digest(fileBytes(file)) === file.sha256, "Immutable File hash verification failed.");
      account(file); files.set(id, file); archive.files.push(file);
      const manifest = chunkManifest(file);
      if (manifest) for (const part of Object.values(manifest.parts)) {
        await loadFile(part.id);
        require(files.get(part.id)?.sha256 === part.sha256, "Missing or mismatched library chunk.");
      }
      await loadDocument(file.documentId);
      progress(`Captured ${archive.records.length} records and ${archive.files.length} immutable File versions.`);
    });
  };
  const captureRecord = async (kind, recordId) => {
    let captured = null;
    await safe("record", recordId, async () => {
      require(!cancelled(), "Export cancelled.");
      const record = parse(await boundary.recordBody({ kind, recordId }));
      require(record.id === recordId && record.type === kind && isObject(record.values) && typeof record.token === "string", "Invalid native record response.");
      record.links = []; record.history = [];
      account(record);
      await safe("links", recordId, () => walkPages(boundary.linkPage, { kind, recordId }, (link) => { account(link); record.links.push(link); }, cancelled));
      if (kind === "Atlas_Ticket__c") await safe("history", recordId, () => walkPages(boundary.historyPage,
        { recordId, cutoff: start.scope.cutoff }, (history) => { account(history); record.history.push(history); }, cancelled));
      captured = record;
    });
    return captured;
  };
  for (const kind of TYPES) {
    if (start.schemas[kind]?.error || !start.schemas[kind]) { issue("object", kind, start.schemas[kind]?.error || "Missing schema."); continue; }
    const rows = [];
    await safe("object", kind, async () => {
      inventories.set(kind, await walkPages(boundary.recordPage, { kind, cutoff: start.scope.cutoff }, (row) => { rows.push(row.Id || row.id); }, cancelled));
    });
    // Each record's body, links and history are independent reads, so four records load at a time.
    // Files stay one at a time in record order: they are shared between records and deduplicated.
    for (const record of await inOrder(rows, PARALLEL_READS, (recordId) => captureRecord(kind, recordId))) {
      if (!record) continue;
      archive.records.push(record);
      for (const id of referencedFiles(record)) await loadFile(id);
      for (const link of record.links) await loadDocument(link.ContentDocumentId);
    }
    progress(`Captured ${archive.records.length} records and ${archive.files.length} immutable File versions.`);
  }
  // No transaction spans these calls. A changed/disappeared record or link is explicitly incomplete.
  await inOrder(archive.records, PARALLEL_READS, (record) => safe("verification", record.id, async () => {
    require(!cancelled(), "Export cancelled.");
    const current = parse(await boundary.recordBody({ kind: record.type, recordId: record.id }));
    require(current.token === record.token, "Record changed during export. Re-export while writers are paused.");
    const links = [];
    await walkPages(boundary.linkPage, { kind: record.type, recordId: record.id }, (link) => links.push(link), cancelled);
    require(JSON.stringify(links) === JSON.stringify(record.links), "File links changed during export.");
  }));
  await inOrder([...inventories], PARALLEL_READS, ([kind, original]) => safe("inventory", kind, async () => {
    const current = await walkPages(boundary.recordPage, { kind, cutoff: start.scope.cutoff }, () => {}, cancelled);
    require(current.size === original.size && [...current].every((id) => original.has(id)), "Accessible record inventory changed during export.");
  }));
  archive.finishedAt = new Date().toISOString();
  archive.completeness.complete = archive.completeness.issues.length === 0;
  archive.completeness.recordCount = archive.records.length;
  archive.completeness.fileVersionCount = archive.files.length;
  const raw = JSON.stringify(archive);
  require(size(raw) <= ARCHIVE_LIMIT, "Workspace exceeds 100 MiB. No truncated backup was produced.");
  return { archive, raw };
}

export async function validateArchive(raw) {
  require(typeof raw === "string" && size(raw) <= ARCHIVE_LIMIT, "Native workspace JSON is limited to 100 MiB.");
  const archive = JSON.parse(raw);
  require(archive?.type === FORMAT && archive.version === 1, "Choose a version-1 native workspace backup, not a legacy HTML or raw library archive.");
  require(isObject(archive.scope) && ["current-user", "accessible-records"].includes(archive.scope.ownership) && isObject(archive.schemas) &&
    Array.isArray(archive.records) && Array.isArray(archive.files) && isObject(archive.completeness) &&
    typeof archive.completeness.complete === "boolean" && Array.isArray(archive.completeness.issues), "Invalid native archive structure.");
  const recordIds = new Set(), fileIds = new Set();
  for (const record of archive.records) {
    require(TYPES.includes(record?.type) && typeof record.id === "string" && record.id && isObject(record.values) &&
      Array.isArray(record.links) && Array.isArray(record.history) && !recordIds.has(record.id), "Invalid or duplicate native record.");
    recordIds.add(record.id);
  }
  for (const file of archive.files) {
    require(isObject(file) && typeof file.id === "string" && file.id && typeof file.documentId === "string" && file.documentId &&
      typeof file.path === "string" && typeof file.title === "string" && Number.isSafeInteger(Number(file.number)) && Number(file.number) > 0 &&
      /^[a-f0-9]{64}$/.test(file.sha256) && !fileIds.has(file.id), "Invalid or duplicate immutable File metadata.");
    fileIds.add(file.id);
    require(await digest(fileBytes(file)) === file.sha256, `File integrity check failed: ${file.id}`);
    chunkManifest(file);
  }
  if (archive.completeness.complete) require(archive.completeness.issues.length === 0, "Archive claims completeness despite recorded omissions.");
  return archive;
}

/** Closure includes all linked/referenced document versions and explicit storage chunk dependencies. */
export function recoveryFiles(archive, record) {
  const byId = new Map(archive.files.map((file) => [file.id, file]));
  const byDocument = new Map();
  for (const file of archive.files) {
    if (!byDocument.has(file.documentId)) byDocument.set(file.documentId, []);
    byDocument.get(file.documentId).push(file);
  }
  const selected = new Map(), documents = new Set();
  const addDocument = (id) => {
    if (documents.has(id)) return;
    documents.add(id);
    require(byDocument.has(id), `Missing attached document ${id}. This record cannot be recovered completely.`);
    for (const file of byDocument.get(id)) add(file.id);
  };
  const add = (id) => {
    if (selected.has(id)) return;
    const file = byId.get(id);
    require(file, `Missing File version ${id}. This record cannot be recovered completely.`);
    selected.set(id, file);
    const manifest = chunkManifest(file);
    if (manifest) for (const part of Object.values(manifest.parts)) {
      require(byId.get(part.id)?.sha256 === part.sha256, `Missing or mismatched chunk ${part.id}.`);
      add(part.id);
    }
    addDocument(file.documentId);
  };
  for (const id of referencedFiles(record)) add(id);
  for (const link of record.links) { require(typeof link.ContentDocumentId === "string", "Invalid File link."); addDocument(link.ContentDocumentId); }
  for (const issue of archive.completeness.issues) {
    require(!([record.id, record.type].includes(issue.id) || selected.has(issue.id) || documents.has(issue.id)),
      `This selection has an export omission/conflict: ${issue.message}`);
  }
  // A current library must be usable JSON; partial upload manifests are retained only as inert history.
  if (record.type === "Atlas_Library__c" && record.values.Kind__c !== "upload" && record.values.Data_File__c) {
    const current = byId.get(record.values.Data_File__c), manifest = chunkManifest(current);
    let raw;
    if (manifest) {
      require(Object.keys(manifest.parts).length === manifest.count &&
        Array.from({ length: manifest.count }, (_, i) => manifest.parts[i]).every(Boolean), "Current library payload has missing chunks.");
      const texts = [];
      let chars = 0, bytes = 0;
      for (let index = 0; index < manifest.count; index++) {
        const part = manifest.parts[index], f = byId.get(part.id);
        const text = new TextDecoder("utf-8", { fatal: true }).decode(fileBytes(f));
        require(text.length === part.chars && f.bytes === part.bytes, "Current library chunk sizes do not match the stored manifest.");
        chars += text.length; bytes += f.bytes;
        require(bytes <= ARCHIVE_LIMIT, "Current library payload exceeds 100 MiB.");
        texts.push(text);
      }
      require(chars === manifest.chars && bytes === manifest.bytes, "Current library total sizes do not match the stored manifest.");
      raw = texts.join("");
    } else {
      require(current.bytes <= 1000000, "Current library File exceeds the storage adapter load limit; a valid chunk manifest is required.");
      raw = new TextDecoder("utf-8", { fatal: true }).decode(fileBytes(current));
    }
    require(isObject(JSON.parse(raw)), "Current library payload must be a JSON object. Original data remains in the source archive.");
  }
  require(selected.size <= 1000, "This selection exceeds 1,000 File versions. No history was silently dropped.");
  const pending = new Map(selected), result = [], done = new Set();
  while (pending.size) {
    let advanced = false;
    for (const [id, file] of pending) {
      const dependencies = Object.values(chunkManifest(file)?.parts || {}).map((p) => p.id);
      const earlier = [...selected.values()].filter((f) => f.documentId === file.documentId && Number(f.number) < Number(file.number)).map((f) => f.id);
      if ([...dependencies, ...earlier].some((dependency) => !done.has(dependency))) continue;
      result.push(file); done.add(id); pending.delete(id); advanced = true;
    }
    require(advanced, "File version/chunk dependencies contain a cycle; automatic recovery is blocked.");
  }
  return result;
}

export async function preserveArchive(pending, progress) {
  if (!pending.saved) {
    const key = `native-workspace:${await digest(new TextEncoder().encode(pending.raw))}:source`;
    pending.saved = parse(await restoreLibrary({ title: "Atlas native workspace recovery source", kind: "workspace",
      dataJson: pending.raw }, key, progress));
  }
  return pending.saved;
}
export async function openArchive(recordId, versionId) {
  require(recordId && versionId, "Choose both a library record ID and an immutable ContentVersion ID.");
  const row = await readLibrary({ recordId, versionId });
  return { raw: row.dataJson, archive: await validateArchive(row.dataJson), saved: { id: recordId, versionId } };
}
export async function prepareRecovery(pending, recordId, references, progress = () => {}, boundary = api) {
  const record = pending.archive.records.find((item) => item.id === recordId);
  require(record, "Select a native record to recover.");
  require(isObject(references), "Reference mappings must be a JSON object of source ID to target ID (or explicit null).");
  const files = recoveryFiles(pending.archive, record);
  const source = await preserveArchive(pending, progress);
  const metadata = Object.fromEntries(files.map(({ base64, ...file }) => [file.id, file]));
  const key = JSON.stringify([recordId, references]);
  if (!pending.plans) pending.plans = new Map();
  let plan = pending.plans.get(key);
  if (!plan) {
    plan = parse(await boundary.prepareRecord({ archiveId: source.id, archiveVersionId: source.versionId,
      recordJson: JSON.stringify(record), filesJson: JSON.stringify(metadata), referencesJson: JSON.stringify(references) }));
    pending.plans.set(key, plan);
  }
  for (let index = 0; index < files.length; index++) {
    await boundary.stageFile({ planId: plan.id, sourceVersionId: files[index].id, base64: files[index].base64 });
    progress(`Staged File version ${index + 1}/${files.length}. No native records changed. Review ${plan.id} is retained privately.`);
  }
  return parse(await boundary.reviewRecord({ planId: plan.id }));
}
export async function resumeReview(planId) { return parse(await reviewRecord({ planId })); }
export async function applyRecovery(review) {
  require(review && review.versionId && review.digest && review.conflicts?.length === 0, "Resolve all recovery conflicts before applying.");
  return parse(await applyRecord({ planId: review.id, reviewedVersionId: review.versionId, reviewedDigest: review.digest }));
}
