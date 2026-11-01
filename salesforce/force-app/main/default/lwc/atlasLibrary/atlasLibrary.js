import { LightningElement, api } from "lwc";
import { loadScript } from "lightning/platformResourceLoader";
import FILES from "@salesforce/resourceUrl/Atlas_Files";
import EXTRACT from "@salesforce/resourceUrl/Atlas_Extract";
import listEntries from "@salesforce/apex/Atlas_Library.listEntries";
import {readLibrary as loadEntry, writeLibrary as saveEntry, readLibrary as loadVersion, restoreLibrary, newLibraryIdentity, inOrder, ARCHIVE_LIMIT} from "c/atlasStorage";
import listVersions from "@salesforce/apex/Atlas_Library.listVersions";

const errorText = (error) => error?.body?.message || error?.message || String(error);
const parse = (value) => typeof value === "string" ? JSON.parse(value) : value;
const EDITOR_FIELDS = ["id", "creationKey", "title", "kind", "revision", "versionId", "dataJson", "savedJson", "savedTitle", "pendingEditors",
    "fieldKey", "fieldJson", "notePath", "notePurpose", "noteText", "briefKey", "briefText", "briefScope", "briefEnabled",
    "featureName", "featureDescription", "featurePaths", "snippetPath", "snippetText", "snippetStart", "snippetEnd",
    "sourcePath", "sourceText", "sourcePrefix", "replaceSource", "sourceStart", "sourceEnd", "packMode", "formRecovery"];
const documentCache = new WeakMap();
const graphCache = new WeakMap();
const validEditor = (fields) => {
    if (!fields || typeof fields !== "object" || Array.isArray(fields)) return false;
    return EDITOR_FIELDS.every((key) => {
        const value = fields[key];
        if (value === undefined) return true;
        if (["id", "versionId"].includes(key)) return value === null || typeof value === "string";
        if (key === "pendingEditors") return Array.isArray(value) && value.every((name) => ["source snapshot", "structured JSON", "file note", "business brief", "feature group", "source snippet"].includes(name));
        if (["replaceSource", "briefEnabled", "formRecovery"].includes(key)) return typeof value === "boolean";
        if (["revision", "sourceStart", "sourceEnd", "snippetStart", "snippetEnd"].includes(key)) return (typeof value === "number" || typeof value === "string") && Number.isSafeInteger(Number(value)) && Number(value) >= 0;
        return typeof value === "string";
    });
};

export default class AtlasLibrary extends LightningElement {
    @api boot;
    @api settings;
    entries = [];
    cursor = null;
    kindFilter = "";
    search = "";
    busy = false;
    problem = "";
    message = "";
    id = null;
    creationKey = "";
    title = "";
    kind = "";
    revision = 0;
    versionId = null;
    dataJson = "";
    savedJson = "";
    savedTitle = "";
    versions = [];
    versionCursor = null;
    pendingImport = null;
    recoverSource = true;
    recoverTask = true;
    recoverFiles = true;
    recoverCurrent = false;
    section = "";
    startLine = 1;
    endLine = 100;
    documentSearch = "";
    matches = [];
    matchCursor = null;
    matchTotal = 0;
    contextText = "";
    contextPath = "";
    contextPage = null;
    contextRequest = null;
    sourcePath = "";
    sourceText = "";
    sourcePrefix = "";
    replaceSource = false;
    sourceStart = 1;
    sourceEnd = 1;
    packMode = "full";
    graph = null;
    graphSearch = "";
    graphOffset = 0;
    fieldKey = "projectNotes";
    fieldJson = '""';
    notePath = "";
    notePurpose = "";
    noteText = "";
    briefKey = "purpose";
    briefText = "";
    briefScope = "";
    briefEnabled = true;
    pendingEditors = [];
    featureName = "";
    featureDescription = "";
    featurePaths = "";
    snippetPath = "";
    snippetText = "";
    snippetStart = 1;
    snippetEnd = 1;
    files;
    libraryPromise;
    extractionRun;
    extractionProgress = "";
    get extracting() { return !!this.extractionRun; }
    get showSpinner() { return this.busy && !this.extracting; }
    get extractionDisabled() { return (this.busy && !this.extracting) || this.dirty || this.pendingEditors.length > 0; }

    get kinds() { return [{ label: "All kinds", value: "" }, ...["document", "notebook", "workspace", "draft"].map((value) => ({ label: value, value }))]; }
    get hasMore() { return Boolean(this.cursor); }
    get hasVersionMore() { return Boolean(this.versionCursor); }
    get hasMatchMore() { return this.matchCursor !== null; }
    get active() { return Boolean(this.kind); }
    get isDocument() { return this.kind === "document"; }
    get isNotebook() { return this.kind === "notebook" || this.kind === "workspace"; }
    get isDraft() { return this.kind === "draft"; }
    get dirty() { return this.dataJson !== this.savedJson || this.title !== this.savedTitle; }
    get navigationDisabled() { return this.busy || this.dirty || this.pendingEditors.length > 0; }
    get saveDisabled() { return this.busy || !this.active || !this.dirty || this.pendingEditors.length > 0; }
    get pendingEditorMessage() { return this.pendingEditors.length ? `Unapplied form edits: ${this.pendingEditors.join(", ")}. Apply each edited form before saving or navigating; the full JSON export does not include these forms yet.` : ""; }
    get briefOptions() { return Object.entries(this.files?.BRIEF_FIELDS || {}).map(([value, label]) => ({ value, label })); }
    get entryRows() {
        return this.entries.map((entry) => ({ ...entry,
            className: "atlas-entry atlas-entry_" + String(entry.kind || "").toLowerCase() + (entry.id === this.id ? " atlas-entry_active" : "") }));
    }
    get noEntries() { return !this.entries.length && !this.busy; }
    get hasVersions() { return this.versions.length > 0; }
    get status() { return `${this.kind || "Library"} · revision ${this.revision}${this.dirty ? " · UNSAVED edits" : " · saved"}`; }
    get documentView() {
        const cached = documentCache.get(this);
        if (cached?.raw === this.dataJson) return cached;
        let document = {}, parsed, valid = false;
        try { parsed = JSON.parse(this.dataJson); valid = true; if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) document = parsed; } catch { /* Keep malformed edits on screen. */ }
        const documentSections = Array.isArray(document.sections) ? document.sections.filter((s) => s && typeof s.text === "string" && typeof s.id === "string") : [];
        const sections = documentSections.map((s) => {
            let lines = 1, at = -1;
            while ((at = s.text.indexOf("\n", at + 1)) !== -1) lines++;
            return {label: `${s.label} (${lines} lines)`, value: s.id};
        });
        const notices = Array.isArray(document.warnings) ? document.warnings : [document.notice];
        const warnings = notices.filter((text) => typeof text === "string" && text).map((text, index) => ({id: String(index), text}));
        // Source lists and counts come from the same parse instead of reparsing the whole notebook each render.
        let sourceOptions = [], sourceSummary = "JSON needs correction before saving.";
        try { sourceOptions = (parsed.sources || []).map((f) => ({label: f.path, value: f.path})); } catch { /* Not a source list. */ }
        try { sourceSummary = `${Object.keys(parsed.notes || {}).length} file notes · ${parsed.groups?.length || 0} feature groups · ${parsed.snippets?.length || 0} saved snippets`; } catch { /* Shown as needing correction. */ }
        if (!valid) sourceSummary = "JSON needs correction before saving.";
        const result = {raw: this.dataJson, document, documentSections, sections, warnings, sourceOptions, sourceSummary};
        documentCache.set(this, result);
        return result;
    }
    get document() { return this.isDocument ? this.documentView.document : {}; }
    get documentSections() { return this.isDocument ? this.documentView.documentSections : []; }
    get warnings() { return this.isDocument ? this.documentView.warnings : []; }
    get sections() { return this.isDocument ? this.documentView.sections : []; }
    get fieldOptions() { return ["projectNotes", "brief", "notes", "groups", "snippets", "sources", "pack", "baseline", "filesAtlas", "taskAtlas"].map((value) => ({ value, label: value })); }
    get sourceOptions() { return this.documentView.sourceOptions; }
    get packModes() { return ["full", "outline", "range"].map((value) => ({label: value, value})); }
    get graphView() {
        const cached = graphCache.get(this);
        if (cached?.graph === this.graph && cached.term === this.graphSearch) return cached;
        const term = this.graphSearch.toLowerCase();
        const refs = (this.graph?.refs || []).filter((r) => !term || [r.file, r.target, r.kind, r.resolution].some((s) => s?.toLowerCase().includes(term)));
        const entities = new Map((this.graph?.entities || []).map((e) => [e.id, e]));
        const result = {graph: this.graph, term: this.graphSearch, refs, entities};
        graphCache.set(this, result);
        return result;
    }
    get graphRefs() { return this.graphView.refs; }
    get graphRows() { const {refs, entities} = this.graphView; return refs.slice(this.graphOffset, this.graphOffset + 50).map((r, i) => ({...r, key: String(this.graphOffset + i), targetPath: r.to ? entities.get(r.to)?.files[0]?.path : null})); }
    get graphSummary() { return this.graph ? `${this.graph.scope} ${this.graph.files.length} files · ${this.graph.entities.length} entities · ${this.graph.edges.length} resolved edges. Showing references ${this.graphRefs.length ? this.graphOffset + 1 : 0}–${Math.min(this.graphOffset + 50, this.graphRefs.length)} of ${this.graphRefs.length} matching references.` : "Analyze the selected saved sources to view dependencies and unresolved references."; }
    get graphMore() { return this.graphOffset + 50 < this.graphRefs.length; }
    get graphPrevious() { return this.graphOffset > 0; }
    get contextMore() { return this.contextPage?.nextOffset != null; }
    get contextSummary() { const p = this.contextPage; return p ? `Characters ${p.offset + 1}–${p.offset + p.text.length} of ${p.totalCharacters}. ${p.nextOffset == null ? "Final page." : "More context remains; use Next context page."}` : ""; }
    get isLibraryImport() { return Boolean(this.pendingImport?.entries); }
    get importEntries() { return this.pendingImport?.entries?.map((e, i) => ({key: String(i), label: `${e.title} · ${e.kind}`, selected: this.pendingImport.selected.includes(i)})) || []; }
    chooseImportEntry(event) {
        const index = Number(event.target.dataset.index), selected = new Set(this.pendingImport.selected);
        if (event.target.checked) selected.add(index); else selected.delete(index);
        this.pendingImport = {...this.pendingImport, selected: [...selected]};
    }
    get importSummary() {
        if (this.isLibraryImport) return `${this.pendingImport.entries.length} saved library entries. Selected entries are recovered as separate copies; existing entries are never overwritten. Repeating this exact import reuses its recovery receipts.`;
        const p = this.pendingImport?.preview;
        return p ? `${p.bytes.toLocaleString()} UTF-8 bytes · ${p.sourceNotes} file notes · ${p.features} feature groups · ${p.tasks} legacy tasks · ${p.filesHistory} earlier Files requests. All ${p.keys.length} top-level fields, including unknown fields, will be archived unchanged.` : "";
    }
    get recoveryAvailable() { return this.isNotebook && Boolean(this.id); }
    get sourceSummary() { return this.documentView.sourceSummary; }

    recoveryStatus = "";
    formRecovery = false;
    recoveryHydrated = false;
    recoveryConnected = false;
    get editorKey() { return this.boot?.org?.id && this.boot?.user?.id ? `atlas-library-editor:${this.boot.org.id}:${this.boot.user.id}` : null; }
    cacheEditor() {
        if (!this.recoveryConnected || !this.editorKey) return false;
        try {
            if (!this.dirty && !this.pendingEditors.length && !this.formRecovery) {
                sessionStorage.removeItem(this.editorKey);
                this.recoveryStatus = "";
                return;
            }
            const fields = Object.fromEntries(EDITOR_FIELDS.map((key) => [key, this[key]]));
            sessionStorage.setItem(this.editorKey, JSON.stringify({ version: 1, fields }));
            this.recoveryStatus = "Unfinished entry and form edits saved in this browser tab. Apply edits and Save new revision to persist them in Salesforce.";
            return true;
        } catch { this.recoveryStatus = "Browser recovery NOT saved (storage unavailable or full). Keep this tab open, apply form edits, then save or export the entry before leaving."; return false; }
    }
    connectedCallback() {
        this.recoveryConnected = true;
        if (this.recoveryHydrated) { this.refresh(); return; }
        try {
            const draft = this.editorKey && JSON.parse(sessionStorage.getItem(this.editorKey) || "null");
            if (draft) {
                const f = draft.fields;
                if (draft.version !== 1 || !validEditor(f) || typeof f.dataJson !== "string" || typeof f.savedJson !== "string" || typeof f.title !== "string" || typeof f.savedTitle !== "string" || !Array.isArray(f.pendingEditors) || !["document", "notebook", "workspace", "draft"].includes(f.kind)) throw Error("Invalid editor recovery");
                for (const key of EDITOR_FIELDS) if (Object.hasOwn(f, key)) this[key] = f[key];
                this.recoveryStatus = "Recovered unfinished entry and form edits from this tab. Recovery itself applies no Salesforce edits. Compare the recovered state with the saved entry before saving again.";
                this.ensureFiles().catch((error) => { this.problem = errorText(error); });
            }
        } catch { this.recoveryStatus = "Browser editor recovery could not be read. Previously saved versions remain in Salesforce."; }
        this.recoveryHydrated = true;
        this.refresh();
    }
    disconnectedCallback() { this.cacheEditor(); this.recoveryConnected = false; this.stopExtraction(); }
    async ensureFiles() {
        if (this.files) return this.files;
        if (!this.libraryPromise) this.libraryPromise = loadScript(this, FILES).then(() => {
            if (!window.AtlasFiles?.checkLibraryJSON) throw Error("The Atlas Files resource needs rebuilding before this library can be used.");
            this.files = window.AtlasFiles;
            return this.files;
        }).catch((error) => { this.libraryPromise = null; throw error; });
        return this.libraryPromise;
    }
    async action(work) {
        if (this.busy) return;
        this.busy = true;
        this.problem = "";
        this.message = "";
        try { await work(); } catch (error) { this.problem = errorText(error); }
        finally { this.busy = false; this.cacheEditor(); }
    }
    async fetchPage(cursor = null) {
        const page = parse(await listEntries({ kind: this.kindFilter, search: this.search, cursor, pageSize: 25 }));
        this.entries = cursor ? [...this.entries, ...page.items] : page.items;
        this.cursor = page.nextCursor;
    }
    @api refresh() { return this.action(() => this.fetchPage()); }
    more() { return this.action(() => this.fetchPage(this.cursor)); }
    filter(event) { this.kindFilter = event.detail.value; this.refresh(); }
    searchInput(event) { this.search = event.target.value; }
    input(event) {
        const key = event.target.dataset.field;
        if (!key || this.busy) return;
        const editor = key === "sourceText" ? "source snapshot" : key === "fieldJson" ? "structured JSON" : ["notePurpose", "noteText"].includes(key) ? "file note" : key.startsWith("brief") ? "business brief" : key.startsWith("feature") ? "feature group" : key.startsWith("snippet") ? "source snippet" : null;
        if (editor && this.pendingEditors.length && !this.pendingEditors.includes(editor)) {
            this.problem = "Apply the current form edits before editing a different form.";
            if (event.target.type === "checkbox") event.target.checked = this[key];
            else event.target.value = this[key];
            return;
        }
        this[key] = event.target.type === "checkbox" ? event.target.checked : event.detail?.value ?? event.target.value;
        if (EDITOR_FIELDS.includes(key) && key !== "title") this.formRecovery = true;
        if (editor && !this.pendingEditors.includes(editor)) this.pendingEditors = [...this.pendingEditors, editor];
        this.cacheEditor();
    }
    applied(editor) { this.pendingEditors = this.pendingEditors.filter((name) => name !== editor); }
    /** Only the form being edited may apply; applying another would resync and replace its unapplied text. */
    claim(editor) {
        const others = this.pendingEditors.filter((name) => name !== editor);
        if (others.length) throw Error(`Apply the current form edits (${others.join(", ")}) before applying a different form.`);
    }
    rawInput(event) {
        if (this.busy) return;
        if (this.pendingEditors.length) { this.problem = "Apply pending form edits before editing the complete JSON."; return; }
        this.dataJson = event.detail?.value ?? event.target.value;
        this.graph = null; this.graphOffset = 0; this.sourceText = ""; this.sourcePath = "";
        this.contextText = "";
        this.syncField();
        this.syncBrief();
        this.cacheEditor();
    }
    adopt(row, raw = row.dataJson) {
        this.id = row.id;
        this.creationKey = row.id ? "" : newLibraryIdentity();
        this.kind = row.kind;
        this.title = row.title;
        this.revision = row.revision;
        this.versionId = row.versionId;
        this.dataJson = raw;
        this.savedJson = raw;
        this.savedTitle = row.title;
        this.formRecovery = false;
        this.versions = [];
        this.versionCursor = null;
        this.contextText = "";
        this.matches = [];
        this.matchCursor = null;
        this.pendingEditors = [];
        this.section = this.sections[0]?.value || "";
        this.startLine = 1;
        this.endLine = Math.min(100, this.documentSections[0]?.text.split("\n").length || 1);
        this.notePath = "";
        this.notePurpose = "";
        this.noteText = "";
        this.sourcePath = "";
        this.sourceText = "";
        this.replaceSource = false;
        this.graph = null;
        this.graphOffset = 0;
        this.contextPage = null;
        this.contextRequest = null;
        this.syncField();
        this.syncBrief();
    }
    open(event) {
        if (this.navigationDisabled) return;
        const recordId = event.currentTarget.dataset.id;
        return this.action(async () => { await this.ensureFiles(); this.adopt(parse(await loadEntry({ recordId }))); });
    }
    createNotebook() { return this.create("notebook", "Source notebook"); }
    createDraft() { return this.create("draft", "Conversation draft"); }
    create(kind, title) {
        if (this.navigationDisabled) return;
        return this.action(async () => {
            const files = await this.ensureFiles();
            const raw = JSON.stringify(kind === "notebook" ? files.newNotebook() : { version: 1, mode: "Source", request: "", paste: "", context: "" }, null, 2);
            this.adopt({ id: null, title, kind, revision: 0, versionId: null, dataJson: raw });
            this.savedJson = "";
            this.savedTitle = "";
        });
    }
    stopExtraction(message = "") {
        const run = this.extractionRun;
        if (!run) return;
        this.extractionRun = null;
        clearTimeout(run.timer);
        run.stop();
        run.job?.cancel();
        this.busy = false;
        this.extractionProgress = message;
    }
    cancelExtraction() { this.stopExtraction("Extraction cancelled. The previous entry is unchanged; nothing was saved."); }
    async extractFile(event) {
        const file = event.target.files?.[0];
        event.target.value = "";
        if (!file || this.extractionDisabled) return;
        this.stopExtraction();
        const run = {};
        const stopped = new Promise((resolve) => { run.stop = resolve; });
        this.extractionRun = run;
        this.busy = true;
        this.problem = "";
        this.message = "";
        this.extractionProgress = `${file.name}: loading background extractor…`;
        run.timer = setTimeout(() => {
            if (this.extractionRun === run) this.stopExtraction("Background extractor loading timed out. Nothing was saved; retry or contact the administrator.");
        }, 60000);
        try {
            if (file.size > 20 * 1024 * 1024) throw Error("Extraction is limited to 20 MB. Use a smaller supported export; no file was saved.");
            if (file.name.length > 80) throw Error("Rename the file to 80 characters or fewer before importing; the original name will not be truncated.");
            const files = await Promise.race([this.ensureFiles(), stopped]);
            if (this.extractionRun !== run) return;
            clearTimeout(run.timer);
            if (!files.startDocumentExtraction) throw Error("Rebuild the Atlas Files and Extract static resources before extracting documents.");
            run.job = files.startDocumentExtraction(file, { workerUrl: EXTRACT, host: this.template.querySelector(".atlas-extraction-host"), mode: "library",
                onProgress: (text) => { if (this.extractionRun === run) this.extractionProgress = `${file.name}: ${text}`; } });
            const raw = await Promise.race([run.job.promise, stopped]);
            if (this.extractionRun !== run) return;
            this.adopt({ id: null, title: file.name, kind: "document", revision: 0, versionId: null, dataJson: raw });
            this.savedJson = "";
            this.savedTitle = "";
            this.extractionProgress = "";
            this.message = "Extraction ready, not yet saved. Review the warnings, then Save. Original binary files can be attached after saving.";
            this.cacheEditor();
        } catch (error) {
            if (this.extractionRun === run) {
                this.problem = errorText(error);
                this.extractionProgress = "Extraction failed. The previous entry is unchanged; nothing was saved.";
            }
        } finally {
            if (this.extractionRun === run) {
                clearTimeout(run.timer);
                run.job?.cancel();
                this.extractionRun = null;
                this.busy = false;
            }
        }
    }
    async persist() {
        if (this.pendingEditors.length) throw Error("Apply pending form edits before saving.");
        const files = await this.ensureFiles();
        files.checkLibraryJSON(this.dataJson);
        const raw = this.dataJson, title = this.title;
        if (!this.id) {
            if (!this.creationKey) this.creationKey = newLibraryIdentity();
            const cached = this.cacheEditor();
            if (!cached && new TextEncoder().encode(raw).length <= 1000000) throw Error("Creation identity could not be saved in this browser tab. Export the entry and keep this tab open; no network write was attempted.");
        }
        const saved = parse(await saveEntry({ recordId: this.id, creationKey: this.creationKey, title, kind: this.kind, expectedRevision: this.revision, dataJson: raw }));
        this.id = saved.id;
        this.creationKey = "";
        this.revision = saved.revision;
        this.versionId = saved.versionId;
        this.savedJson = raw;
        this.savedTitle = title;
        this.formRecovery = false;
        this.message = `Saved revision ${saved.revision}. Earlier JSON versions are retained in Salesforce Files.`;
        await this.fetchPage();
        return saved;
    }
    save() { return this.action(() => this.persist()); }
    originalsUploaded(event) { this.message = `${event.detail.files.length} original file(s) attached in Salesforce Files. These do not replace the saved extraction.`; }
    download(name, text) {
        const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
        const link = document.createElement("a");
        link.href = url;
        link.download = name;
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    exportEntry() {
        if (!this.active) return;
        if (this.pendingEditors.length) { this.problem = "Apply pending form edits before exporting the full entry."; return; }
        this.download("atlas-" + (this.title || "library").replace(/[^a-z0-9_-]/gi, "-") + ".json", this.dataJson);
        this.message = "Full JSON download requested, including unknown fields and any unsaved edits. Keep this unencrypted backup private.";
    }
    exportAll() {
        return this.action(async () => {
            const entries = [], seen = new Set();
            let cursor = null, bytes = 0;
            do {
                const page = parse(await listEntries({ kind: null, search: "", cursor, pageSize: 50 }));
                // Each page's entries load four at a time and keep their order.
                entries.push(...await inOrder(page.items, 4, async (item) => {
                    const row = parse(await loadEntry({ recordId: item.id }));
                    bytes += new TextEncoder().encode(JSON.stringify(row)).length;
                    if (bytes > ARCHIVE_LIMIT - 10000) throw Error("The library exceeds the 100 MiB single-archive limit. Nothing was downloaded. Export individual entries instead.");
                    return row;
                }));
                cursor = page.nextCursor;
                if (cursor && seen.has(cursor)) throw Error("Library paging repeated a cursor. Export stopped rather than producing an incomplete archive.");
                seen.add(cursor);
            } while (cursor);
            const raw = JSON.stringify({ type: "atlas-library-export", version: 1, exportedAt: new Date().toISOString(), entries });
            if (new TextEncoder().encode(raw).length > ARCHIVE_LIMIT) throw Error("The complete library archive exceeds 100 MiB. Nothing was downloaded; export individual entries instead.");
            this.download("atlas-full-library.json", raw);
            this.message = `Exported ${entries.length} complete saved JSON entries. Unsaved edits are not included. Originals attached with Salesforce Files are separate; download those from Salesforce. This is not an atomic cross-record snapshot.`;
        });
    }
    previewImport(event) {
        const file = event.target.files?.[0];
        if (!file || this.busy) return;
        return this.action(async () => {
            if (this.dirty) throw Error("Save current edits before previewing a recovery into this library.");
            const files = await this.ensureFiles();
            if (file.size > files.MAX_LIBRARY_BYTES) throw Error("Workspace JSON exceeds 100 MiB. Nothing was imported; the original remains unchanged.");
            const raw = await file.text(), preview = files.workspacePreview(raw), data = JSON.parse(raw);
            if (data.type === "atlas-library-export") {
                if (data.version !== 1 || !Array.isArray(data.entries)) throw Error("Unsupported library archive version or entries.");
                for (const entry of data.entries) {
                    if (!entry || !["document","notebook","workspace","draft"].includes(entry.kind) || typeof entry.title !== "string" || !entry.title.trim() || entry.title.length > 80)
                        throw Error("Every archived entry must have its original title and supported kind. No records were changed.");
                    files.checkLibraryJSON(entry.dataJson);
                }
                this.pendingImport = {raw, preview, entries: data.entries, selected: data.entries.map((_, i) => i), archive: null};
                return;
            }
            this.pendingImport = { raw, preview, archive: null };
            this.recoverSource = true;
            this.recoverTask = preview.hasTasks;
            this.recoverFiles = preview.hasFiles;
            this.recoverCurrent = false;
        });
    }
    cancelImport() { if (!this.busy) this.pendingImport = null; }
    confirmImport() {
        return this.action(async () => {
            if (!this.pendingImport) return;
            const files = await this.ensureFiles(), pending = this.pendingImport;
            if (pending.entries) {
                if (!pending.selected.length) throw Error("Select at least one library entry to recover.");
                if (this.dirty || this.pendingEditors.length) throw Error("Save current edits before confirming import.");
                const identity = await files.fingerprint(pending.raw);
                if (!pending.archive) pending.archive = await restoreLibrary({title: "Original library recovery archive", kind: "workspace", dataJson: pending.raw}, `library:${identity}:archive`);
                for (const index of pending.selected) {
                    const entry = pending.entries[index];
                    await restoreLibrary({title: entry.title, kind: entry.kind, dataJson: entry.dataJson}, `library:${identity}:${index}`,
                        (text) => { this.message = text; });
                    this.message = `Recovered ${entry.title}. Continuing selected entries…`;
                }
                const count = pending.selected.length;
                this.pendingImport = null;
                await this.fetchPage();
                this.message = `Recovered ${count} selected library entries as separate copies. Original archive preserved unchanged. Existing entries were not overwritten; Jira and Salesforce metadata were not changed.`;
                return;
            }
            const areas = { source: this.recoverSource, task: this.recoverTask, files: this.recoverFiles };
            if (!Object.values(areas).some(Boolean)) throw Error("Select at least one recovery area; the complete original will still be archived.");
            if (this.dirty || this.pendingEditors.length) throw Error("Save current edits before confirming import.");
            if (this.recoverCurrent && !this.recoveryAvailable) throw Error("Select a saved source notebook or workspace for recovery.");
            const recovered = this.recoverCurrent ? files.recoverWorkspace(this.dataJson, pending.raw, areas) : null;
            if (!pending.archive) {
                pending.archive = await restoreLibrary({ title: "Imported workspace backup", kind: "workspace", dataJson: pending.raw }, `workspace:${await files.fingerprint(pending.raw)}:archive`);
            }
            const archive = pending.archive;
            let recoveredId = null;
            if (recovered !== null) {
                const saved = parse(await saveEntry({ recordId: this.id, title: this.title, kind: this.kind, expectedRevision: this.revision, dataJson: recovered }));
                this.adopt(saved, recovered);
                recoveredId = saved.id;
            } else this.adopt(archive, pending.raw);
            const workspace = JSON.parse(pending.raw);
            if (!workspace.workspace) workspace.workspace = "archive:" + await files.fingerprint(pending.raw);
            this.dispatchEvent(new CustomEvent("imported", { detail: { libraryId: archive.id, recoveredId, workspace, taskAtlas: workspace.taskAtlas, rawWorkspaceJson: pending.raw, areas } }));
            this.pendingImport = null;
            this.message = "Full backup archived unchanged. Selected library recovery is complete. If Tasks were selected, the host now attempts the native ticket migration and shows any conflict with a retry option; check Tickets for its result.";
            await this.fetchPage();
        });
    }
    history() { return this.action(() => this.fetchVersions(null)); }
    moreVersions() { return this.action(() => this.fetchVersions(this.versionCursor)); }
    async fetchVersions(cursor) {
        const page = parse(await listVersions({ recordId: this.id, cursor, pageSize: 25 }));
        this.versions = cursor ? [...this.versions, ...page.items] : page.items;
        this.versionCursor = page.nextCursor;
    }
    openVersion(event) {
        if (this.navigationDisabled) return;
        return this.action(async () => {
            const row = parse(await loadVersion({ recordId: this.id, versionId: event.currentTarget.dataset.id }));
            // Keep the current optimistic revision; Save creates a new version, never erases history.
            this.dataJson = row.dataJson;
            this.graph = null; this.graphOffset = 0; this.sourceText = ""; this.sourcePath = "";
            this.contextText = "";
            this.syncField();
            this.syncBrief();
            this.message = "Historical JSON loaded for review. Export it or Save as a new revision; no existing version is deleted.";
        });
    }
    sectionChanged(event) {
        this.section = event.detail.value;
        const section = this.document.sections?.find((s) => s.id === this.section);
        this.startLine = 1;
        this.endLine = Math.min(100, section?.text.split("\n").length || 1);
    }
    findText() { return this.action(() => this.findMatches(0)); }
    moreMatches() { return this.action(() => this.findMatches(this.matchCursor)); }
    async findMatches(cursor) {
        const files = await this.ensureFiles();
        const result = files.searchDocument(this.document, this.documentSearch, cursor);
        const rows = result.matches.map((m) => ({ ...m, id: `${m.section}:${m.line}` }));
        this.matches = cursor ? [...this.matches, ...rows] : rows;
        this.matchTotal = result.total;
        this.matchCursor = result.nextCursor;
    }
    useMatch(event) {
        this.section = event.currentTarget.dataset.section;
        this.startLine = Number(event.currentTarget.dataset.line);
        this.endLine = this.startLine;
    }
    documentContext() { return this.previewContext("document", {section: this.section, start: Number(this.startLine), end: Number(this.endLine)}); }
    outlineContext() { return this.previewContext("document", {}); }
    notebookContext() { return this.previewContext("notebook", {path: this.contextPath}); }
    sourceContext() { return this.previewContext("source", {path: this.sourcePath, start: Number(this.sourceStart), end: Number(this.sourceEnd)}); }
    packContext() { return this.previewContext("pack", {}); }
    previewContext(view, query) {
        return this.action(async () => {
            if (this.pendingEditors.length) throw Error("Apply pending form edits before generating context.");
            this.contextRequest = {view, query, raw: this.dataJson};
            await this.renderContextPage(0);
        });
    }
    nextContext() { return this.action(() => this.renderContextPage(this.contextPage.nextOffset)); }
    async renderContextPage(offset) {
        const files = await this.ensureFiles(), request = this.contextRequest, paging = {offset, maxChars: 20000};
        const page = request.view === "document" ? files.libraryDocumentContext(JSON.parse(request.raw), request.query, paging)
            : request.view === "source" ? files.sourceFileContext(request.raw, {...request.query, ...paging})
            : request.view === "pack" ? files.sourcePackContext(request.raw, paging)
            : files.sourceNotebookContext(request.raw, request.query.path, paging);
        this.contextPage = page;
        this.contextText = page.text;
    }
    loadSource(event) {
        if (this.pendingEditors.length) { this.problem = "Apply pending edits before choosing another source."; return; }
        this.sourcePath = event.detail?.value ?? event.currentTarget.dataset.path;
        const source = JSON.parse(this.dataJson).sources?.find((f) => f.path === this.sourcePath);
        this.sourceText = source?.text || "";
        this.sourceStart = 1;
        this.sourceEnd = Math.min(100, this.sourceText.split("\n").length);
        this.replaceSource = false;
    }
    applySource() {
        return this.action(async () => {
            this.claim("source snapshot");
            const files = await this.ensureFiles();
            this.dataJson = await files.saveSourceSnapshot(this.dataJson, {path: this.sourcePath, text: this.sourceText}, this.replaceSource);
            this.applied("source snapshot");
            this.graph = null;
            this.contextText = "";
            this.syncField();
            this.message = "Source snapshot applied locally. Save a revision to persist it; this does not deploy or change the org.";
        });
    }
    importSources(event) {
        const selected = Array.from(event.target.files || []);
        if (!selected.length) return;
        return this.action(async () => {
            if (this.pendingEditors.length) throw Error("Apply pending edits before importing source files.");
            const files = await this.ensureFiles();
            let raw = this.dataJson;
            for (const file of selected) {
                if (file.size > 20 * 1024 * 1024) throw Error(`${file.name} exceeds 20 MiB. No imported files applied.`);
                const text = new TextDecoder("utf-8", {fatal: true}).decode(await file.arrayBuffer());
                const path = [this.sourcePrefix.replace(/\/$/, ""), file.webkitRelativePath || file.name].filter(Boolean).join("/");
                raw = await files.saveSourceSnapshot(raw, {path, text});
            }
            this.dataJson = raw;
            this.graph = null;
            this.contextText = "";
            this.syncField();
            this.message = `${selected.length} source snapshots applied locally. Existing different text was not overwritten. Save to persist.`;
        });
    }
    analyzeSources() { return this.action(async () => { const files = await this.ensureFiles(); this.graph = files.sourceGraph(this.dataJson); this.graphOffset = 0; }); }
    searchGraph(event) { this.graphSearch = event.target.value; this.graphOffset = 0; }
    nextGraph() { this.graphOffset += 50; }
    previousGraph() { this.graphOffset = Math.max(0, this.graphOffset - 50); }
    selectPack() {
        return this.action(async () => {
            if (this.pendingEditors.length) throw Error("Apply pending edits before selecting a context pack.");
            const files = await this.ensureFiles();
            this.dataJson = files.savePackSelection(this.dataJson, {path: this.sourcePath, mode: this.packMode, start: Number(this.sourceStart), end: Number(this.sourceEnd)});
            this.contextText = "";
            this.syncField();
            this.message = "Context pack selection applied locally. Save to persist. Use the pack JSON field to inspect or edit all selections.";
        });
    }
    handoff() { if (this.contextText) this.dispatchEvent(new CustomEvent("context", { detail: { text: this.contextText } })); }
    syncField() {
        if (this.pendingEditors.includes("structured JSON")) return;
        try { this.fieldJson = this.files?.jsonFields(this.dataJson).get(this.fieldKey) || (this.fieldKey === "projectNotes" ? '""' : ["groups", "pack", "snippets"].includes(this.fieldKey) ? "[]" : "{}"); }
        catch { this.fieldJson = ""; }
    }
    fieldChanged(event) {
        if (this.pendingEditors.includes("structured JSON")) { this.problem = "Apply the edited field before choosing another field."; return; }
        this.fieldKey = event.detail.value;
        this.syncField();
    }
    syncBrief() {
        if (this.pendingEditors.includes("business brief")) return;
        try {
            const briefRaw = this.files?.jsonFields(this.dataJson).get("brief") || "{}";
            const item = JSON.parse(this.files?.jsonFields(briefRaw).get(this.briefKey) || "{}");
            this.briefText = typeof item.text === "string" ? item.text : "";
            this.briefScope = typeof item.scope === "string" ? item.scope : "";
            this.briefEnabled = item.enabled !== false;
        } catch { this.briefText = ""; this.briefScope = ""; this.briefEnabled = true; }
    }
    briefChanged(event) {
        if (this.pendingEditors.includes("business brief")) { this.problem = "Apply the edited business brief before choosing another section."; return; }
        this.briefKey = event.detail.value;
        this.syncBrief();
    }
    applyBrief() {
        return this.action(async () => {
            this.claim("business brief");
            const files = await this.ensureFiles();
            const briefRaw = files.jsonFields(this.dataJson).get("brief") || "{}";
            const old = files.jsonFields(briefRaw).get(this.briefKey) || "{}";
            const item = files.patchLibraryJSON(old, { text: this.briefText, scope: this.briefScope, enabled: this.briefEnabled });
            const brief = files.patchLibraryField(briefRaw, this.briefKey, item);
            this.dataJson = files.patchLibraryField(this.dataJson, "brief", brief);
            this.applied("business brief");
            this.contextText = "";
            this.syncField();
            this.message = "Business brief section applied locally. Save to persist it.";
        });
    }
    applyField() {
        return this.action(async () => {
            this.claim("structured JSON");
            const files = await this.ensureFiles();
            this.dataJson = files.patchLibraryField(this.dataJson, this.fieldKey, this.fieldJson);
            if (this.fieldKey === "sources") { this.graph = null; this.graphOffset = 0; this.sourceText = ""; this.sourcePath = ""; }
            this.applied("structured JSON");
            this.syncBrief();
            this.contextText = "";
            this.message = "Field applied locally without normalizing other fields. Save to create a persistent revision.";
        });
    }
    loadNote() {
        return this.action(async () => {
            if (this.pendingEditors.includes("file note")) throw Error("Apply the edited note before loading another note.");
            const files = await this.ensureFiles(), fields = files.jsonFields(this.dataJson);
            const notes = JSON.parse(fields.get("notes") || "{}");
            const note = Object.hasOwn(notes, this.notePath) ? notes[this.notePath] : {};
            this.notePurpose = note.purpose || "";
            this.noteText = note.notes || "";
        });
    }
    applyNote() {
        return this.action(async () => {
            this.claim("file note");
            if (!this.notePath.trim()) throw Error("Enter a file path or metadata name; no local folder is required.");
            const files = await this.ensureFiles(), fields = files.jsonFields(this.dataJson);
            const notesRaw = fields.get("notes") || "{}";
            const oldNote = files.jsonFields(notesRaw).get(this.notePath) || "{}";
            const note = files.patchLibraryJSON(oldNote, { purpose: this.notePurpose, notes: this.noteText });
            const notes = files.patchLibraryField(notesRaw, this.notePath, note);
            this.dataJson = files.patchLibraryField(this.dataJson, "notes", notes);
            this.applied("file note");
            this.contextText = "";
            this.syncField();
            this.message = "File note applied locally. Save to persist it.";
        });
    }
    addFeature() {
        return this.action(async () => {
            this.claim("feature group");
            if (!this.featureName.trim()) throw Error("Enter a feature name.");
            const files = await this.ensureFiles();
            this.dataJson = files.appendLibraryItem(this.dataJson, "groups", { id: "feature-" + Date.now(), name: this.featureName, description: this.featureDescription, paths: this.featurePaths.split("\n").map((s) => s.trim()).filter(Boolean) });
            this.featureName = "";
            this.featureDescription = "";
            this.featurePaths = "";
            this.applied("feature group");
            this.contextText = "";
            this.syncField();
            this.message = "Feature group added locally. Save to persist it.";
        });
    }
    addSnippet() {
        return this.action(async () => {
            this.claim("source snippet");
            const start = Number(this.snippetStart), end = Number(this.snippetEnd);
            if (!this.snippetPath.trim() || !this.snippetText || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start)
                throw Error("Enter a path, snippet text, and a valid 1-based source line range.");
            const files = await this.ensureFiles();
            this.dataJson = files.appendLibraryItem(this.dataJson, "snippets", { path: this.snippetPath, start, end, text: this.snippetText });
            this.snippetText = "";
            this.applied("source snippet");
            this.contextText = "";
            this.syncField();
            this.message = "Snippet added locally with its file context. Save to persist it.";
        });
    }
    restoreDraft() {
        if (!this.isDraft || this.dirty) return;
        this.dispatchEvent(new CustomEvent("draft", { detail: { libraryId: this.id, revision: this.revision, dataJson: this.dataJson, draft: JSON.parse(this.dataJson) } }));
        this.message = "Saved draft handed to the host for review. Check Tickets for Jira operations or Work for conversation drafts; the host must confirm restoration. Nothing was applied automatically.";
    }
}
