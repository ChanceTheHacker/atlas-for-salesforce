// Jira stays manual: Atlas writes a CSV for Jira's importer and reads Jira's CSV export.
import { findPerson as resolvePerson } from "./tickets";
import { parseJiraDate, parseJiraDateTime, suggestedDueDate } from "./dates";

const canonical = (h) =>
  String(h ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");

export function parseCSV(text, delimiter) {
  text = String(text ?? "").replace(/^﻿/, "");
  if (!delimiter) {
    const first = text.split(/\r?\n/)[0] || "";
    delimiter = [",", "\t", ";"]
      .map((d) => ({ d, n: first.split(d).length }))
      .sort((a, b) => b.n - a.n)[0].d;
  }
  const rows = [];
  let row = [],
    cell = "",
    quoted = false,
    closed = false;
  const endRow = () => {
    row.push(cell);
    if (row.some((x) => x !== "")) rows.push(row);
    row = [];
    cell = "";
    closed = false;
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c !== '"') cell += c;
      else if (text[i + 1] === '"') {
        cell += '"';
        i++;
      } else {
        quoted = false;
        closed = true;
      }
    } else if (c === '"' && !cell && !closed) quoted = true;
    else if (c === delimiter) {
      row.push(cell);
      cell = "";
      closed = false;
    } else if (c === "\r" || c === "\n") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      endRow();
    } else if (!closed) cell += c;
    else if (c !== " " && c !== "\t")
      throw new Error(
        `Line ${rows.length + 1}: text after a closing quote. Check the CSV quoting.`,
      );
  }
  if (quoted)
    throw new Error("The CSV has a quoted value that never closes.");
  if (cell !== "" || row.length) endRow();
  if (rows.length < 2)
    throw new Error("The CSV needs a header row and at least one issue row.");
  return { headers: rows[0], rows: rows.slice(1), delimiter };
}

export function csvText(headers, rows, delimiter = ",") {
  const quote = (v) => '"' + String(v ?? "").replace(/"/g, '""') + '"';
  return (
    "﻿" +
    [headers, ...rows].map((r) => r.map(quote).join(delimiter)).join("\r\n") +
    "\r\n"
  );
}

// ---- Jira import configuration (the .txt Jira's CSV importer saves) ----

// Each export column, the Jira field it fills and the header names that mean it.
const COLUMNS = [
  { id: "summary", header: "Summary", jira: ["summary"] },
  { id: "issueType", header: "Issue Type", jira: ["issuetype"] },
  { id: "description", header: "Description", jira: ["description"] },
  { id: "priority", header: "Priority", jira: ["priority"] },
  { id: "dueDate", header: "Due Date", jira: ["duedate"] },
  { id: "epicName", header: "Epic Name", names: ["epicname"] },
  { id: "epicLink", header: "Epic Link", jira: ["parent"], names: ["epiclink", "parent", "parentkey", "parentid"] },
  { id: "assignee", header: "Assignee", jira: ["assignee"] },
  { id: "reporter", header: "Reporter", jira: ["reporter"] },
];

/**
 * Reads a saved Jira import configuration. Accepts Jira's own JSON file
 * ("config.field.mappings" and friends) or simple lines such as
 * "Due Date = Due date" (Atlas column = header Jira expects).
 */
export function parseMapping(text) {
  const raw = String(text ?? "").replace(/^﻿/, "").trim();
  if (!raw) throw new Error("The mapping file is empty.");
  let json = null;
  try {
    json = JSON.parse(raw);
  } catch {
    /* not JSON: try the simple line format */
  }
  const mapping = {
    headers: {},
    customHeaders: {},
    delimiter: ",",
    dateFormat: "",
    projectKey: "",
    values: {},
    unmapped: [],
  };
  if (json && typeof json === "object") {
    const fields = json["config.field.mappings"] || {};
    if (!Object.keys(fields).length)
      throw new Error(
        'This JSON has no "config.field.mappings". Use the configuration file Jira\'s CSV importer saves.',
      );
    for (const [csvHeader, target] of Object.entries(fields)) {
      const jiraField = canonical(target?.["jira.field"]);
      const name = canonical(csvHeader);
      const column = COLUMNS.find(
        (c) => c.jira?.includes(jiraField) || c.names?.includes(name),
      );
      if (column) {
        if (Object.hasOwn(mapping.headers, column.id)) throw Error(`Multiple headers map to ${column.header}; choose one explicitly.`);
        mapping.headers[column.id] = csvHeader;
      } else { mapping.unmapped.push(csvHeader); mapping.customHeaders[csvHeader] = csvHeader; }
    }
    const delimiter = json["config.delimiter"];
    if (delimiter) mapping.delimiter = delimiter === "\\t" ? "\t" : delimiter;
    mapping.dateFormat = json["config.date.format"] || "";
    mapping.projectKey = json["config.project"]?.["project.key"] || "";
    for (const [csvHeader, values] of Object.entries(
      json["config.value.mappings"] || {},
    )) {
      const column = Object.entries(mapping.headers).find(
        ([, h]) => h === csvHeader,
      );
      if (column && values && typeof values === "object")
        mapping.values[column[0]] = values;
      else if (Object.hasOwn(mapping.customHeaders, csvHeader) && values && typeof values === "object") mapping.values["custom:" + csvHeader] = values;
    }
  } else {
    for (const line of raw.split(/\r?\n/)) {
      const m = /^\s*([^=:>\t]+?)\s*(?:=|->|=>|:|\t)\s*(.+?)\s*$/.exec(line);
      if (!m) continue;
      const column = COLUMNS.find(
        (c) =>
          canonical(c.header) === canonical(m[1]) ||
          c.names?.includes(canonical(m[1])),
      );
      const target = column ? mapping.headers : mapping.customHeaders, key = column?.id || m[1];
      if (Object.hasOwn(target, key)) throw Error(`Repeated mapping for ${m[1]}; choose one explicitly.`);
      target[key] = m[2];
      if (!column) mapping.unmapped.push(m[1]);
    }
    if (!Object.keys(mapping.headers).length && !Object.keys(mapping.customHeaders).length)
      throw new Error(
        'No mappings found. Use Jira\'s saved import configuration, or lines like "Due Date = Due date".',
      );
  }
  const headers = [...Object.values(mapping.headers), ...Object.values(mapping.customHeaders)];
  if (new Set(headers).size !== headers.length) throw Error("Multiple fields map to the same CSV header; resolve the mapping before import or export.");
  return mapping;
}

/** One line per column, for the setup screen. */
export function describeMapping(mapping) {
  if (!mapping) return [];
  const lines = COLUMNS.map(
    (c) =>
      `${c.header} → ${mapping.headers[c.id] ? `"${mapping.headers[c.id]}"` : "same name (not in the file)"}`,
  );
  for (const [name, header] of Object.entries(mapping.customHeaders || {})) lines.push(`Custom ${name} → "${header}" (exact text; only exported when present)`);
  if (mapping.dateFormat) lines.push(`Dates written as ${mapping.dateFormat}`);
  if (mapping.delimiter !== ",")
    lines.push(`Separator: ${mapping.delimiter === "\t" ? "tab" : mapping.delimiter}`);
  if (mapping.projectKey) lines.push(`Project: ${mapping.projectKey}`);
  return lines;
}

const MONTH_NAMES = "January February March April May June July August September October November December".split(" ");

/** Writes YYYY-MM-DD in a Java SimpleDateFormat pattern such as dd/MMM/yy h:mm a. */
export function formatDate(iso, pattern) {
  if (!iso || !pattern) return iso || "";
  const [y, mo, d] = iso.split("-").map(Number);
  const tokens = {
    yyyy: String(y),
    yy: String(y).slice(2),
    MMMM: MONTH_NAMES[mo - 1],
    MMM: MONTH_NAMES[mo - 1].slice(0, 3),
    MM: String(mo).padStart(2, "0"),
    M: String(mo),
    dd: String(d).padStart(2, "0"),
    d: String(d),
    HH: "00",
    H: "0",
    hh: "12",
    h: "12",
    mm: "00",
    ss: "00",
    a: "AM",
  };
  return pattern.replace(
    /'([^']*)'|yyyy|yy|MMMM|MMM|MM|M|dd|d|HH|H|hh|h|mm|ss|a/g,
    (t, quoted) => (quoted !== undefined ? quoted : tokens[t]),
  );
}

function mapValue(mapping, column, value) {
  const values = mapping?.values?.[column];
  if (!values || value === "") return value;
  // Jira maps CSV value -> Jira value; write the CSV value that becomes ours.
  const text = String(value);
  const entries = Object.entries(values);
  const found = entries.find(([, target]) => String(target) === text)
    || entries.find(([, target]) => String(target).toLowerCase() === text.toLowerCase());
  if (found) return found[0];
  // Writing the value unchanged is only safe when Jira will not turn it into something else.
  if (Object.hasOwn(values, text) && String(values[text]).toLowerCase() !== text.toLowerCase())
    throw new Error(`${mapping?.headers?.[column] || column} "${text}" would import into Jira as "${values[text]}". Add a value to the Jira import mapping that becomes "${text}", or change the ticket.`);
  return value;
}

/**
 * The CSV for Jira's importer. Headers, separator, dates and values follow the
 * saved mapping, so Jira matches every column without a second file.
 */
export function exportCSV(tickets, { people = [], mapping = null, me = null } = {}) {
  const byId = new Map(tickets.map((t) => [t.id, t]));
  const jiraId = (personId) => {
    const person = people.find((p) => p.id === personId);
    if (person?.identityWarning || person?.active === false) throw Error(`Reconcile ${person.name}'s Salesforce/Jira identity in Team & Jira before export.`);
    return person?.jiraId || "";
  };
  const warnings = [];
  const withReporter = tickets.some((t) => t.reporterId);
  const columns = COLUMNS.filter((c) => c.id !== "reporter" || withReporter);
  const custom = [...new Set(tickets.flatMap((t) => Object.keys(t.planning?.customFields || {})))];
  for (const key of custom) columns.push({id: "custom:" + key, key, header: mapping?.customHeaders?.[key] || key});
  const rows = tickets.map((t) => {
    const epic = t.epicId ? byId.get(t.epicId) : null;
    let epicLink = "";
    if (t.issueType !== "Epic") {
      epicLink = t.epicKey || "";
      if (!epicLink && epic) epicLink = epic.jiraKey || "";
      if ((t.epicId || epicLink) && !/^[A-Z][A-Z0-9_]*-\d+$/.test(epicLink))
        throw new Error(`${t.atlasId || t.id}: unresolved epic. Export the epic first, import it in Jira, then confirm its real Jira key.`);
    }
    if (t.planning?.unresolvedAssignee || t.planning?.unresolvedReporter)
      throw new Error(`${t.atlasId || t.id}: reconcile the legacy/imported Jira identity before export.`);
    const assignee = jiraId(t.assigneeId);
    for (const field of ["assignee", "reporter"]) if (t[field + "Id"] && !jiraId(t[field + "Id"]))
      throw new Error(`${t.atlasId || t.id}: ${field} needs a confirmed Jira account ID in Team & Jira before export.`);
    const dueDate = t.dueDate || suggestedDueDate().dueDate;
    const values = {
      summary: t.summary,
      issueType: t.issueType,
      description: t.description || "",
      priority: t.priority || "",
      dueDate: formatDate(dueDate, mapping?.dateFormat),
      epicName: t.issueType === "Epic" ? t.epicName || t.summary : "",
      epicLink,
      assignee,
      reporter: jiraId(t.reporterId),
    };
    return columns.map((c) => mapValue(mapping, c.id, (c.key ? t.planning?.customFields?.[c.key] : values[c.id]) ?? ""));
  });
  const headers = columns.map((c) => mapping?.headers?.[c.id] || c.header);
  if (new Set(headers).size !== headers.length) throw new Error("Export columns have conflicting headers. Review the standard/custom field mapping before exporting.");
  return {
    headers,
    rows,
    warnings,
    csv: csvText(headers, rows, mapping?.delimiter || ","),
  };
}

// ---- Reading Jira's CSV export ----

const IMPORT_COLUMNS = {
  key: ["issuekey", "workitemkey", "key"],
  summary: ["summary"],
  description: ["description"],
  issueType: ["issuetype", "worktype", "type"],
  status: ["status"],
  statusCategory: ["statuscategory"],
  assignee: ["assigneeid", "assigneeaccountid", "assignee"],
  priority: ["priority"],
  dueDate: ["duedate"],
  epicKey: ["customfieldepiclink", "epiclink", "parent", "parentkey", "parentid"],
  epicName: ["customfieldepicname", "epicname"],
  updated: ["updated", "updateddate"],
  project: ["projectkey", "spacekey"],
};

/** Which CSV column feeds each ticket field (-1 when the export lacks it). */
export function importColumns(headers, mapping) {
  const map = {};
  for (const [field, names] of Object.entries(IMPORT_COLUMNS)) {
    const mapped = mapping?.headers?.[field === "epicKey" ? "epicLink" : field];
    let matches = mapped ? headers.flatMap((h, i) => h === mapped ? [i] : []) : [];
    for (const name of names) {
      if (matches.length) break;
      matches = headers.flatMap((h, i) => canonical(h) === name ? [i] : []);
    }
    if (matches.length > 1) throw Error(`Ambiguous CSV columns for ${field}; rename or explicitly map one column before importing. No rows imported.`);
    map[field] = matches[0] ?? -1;
  }
  return map;
}

function statusCategory(status) {
  const s = canonical(status);
  if (/^(done|closed|resolved|complete|completed|cancelled|canceled|released)$/.test(s)) return "Done";
  if (/^(todo|open|new|backlog|selectedfordevelopment|ready|reopened)$/.test(s)) return "To Do";
  return s ? "In Progress" : "";
}

/** Jira's export rows in the shape Atlas_Tickets.importJira expects. */
export function importRows(parsed, { people = [], mapping = null } = {}) {
  const map = importColumns(parsed.headers, mapping);
  if (map.key < 0 || map.summary < 0)
    throw new Error('The CSV needs "Issue key" and "Summary" columns. Export all fields from a Jira search.');
  const findPerson = (value) => {
    const found = resolvePerson(people, value);
    if (/^(?:my\s+)?manager$/i.test(value.trim()) && !found?.jiraId)
      throw new Error('The manager is not a unique, verified Jira identity. Reconcile Team & Jira before importing; role words are not literal Jira IDs.');
    return found?.jiraId || value.trim();
  };
  const cell = (row, field) =>
    map[field] >= 0 ? String(row[map[field]] ?? "").trim() : undefined;
  const headerCounts = new Map(), customMapping = new Map(), used = new Set(Object.values(map));
  for (const header of parsed.headers) headerCounts.set(header, (headerCounts.get(header) || 0) + 1);
  for (const [key, header] of Object.entries(mapping?.customHeaders || {})) {
    if (customMapping.has(header)) throw Error(`Ambiguous custom mapping for ${header}. No rows imported.`);
    customMapping.set(header, key);
  }
  const customColumns = [], customKeys = new Set();
  parsed.headers.forEach((header, index) => {
    if (!header || used.has(index) || headerCounts.get(header) !== 1) return;
    const key = customMapping.get(header) || header;
    if (customKeys.has(key)) throw Error(`Multiple CSV columns resolve to custom field ${key}. No rows imported.`);
    customKeys.add(key); customColumns.push({key,index});
  });
  const skipped = [];
  const rows = [];
  const seen = new Set();
  parsed.rows.forEach((row, i) => {
    const key = cell(row, "key");
    if (key && seen.has(key.toUpperCase())) throw new Error(`Duplicate Jira key ${key} at row ${i + 2}. No rows imported.`);
    if (key) seen.add(key.toUpperCase());
    if (!/^[A-Z][A-Z0-9_]*-\d+$/i.test(key || "")) {
      skipped.push(`Row ${i + 2}: "${key}" is not a Jira key.`);
      return;
    }
    const out = { key: key.toUpperCase(), summary: cell(row, "summary"), raw: { headers: [...parsed.headers], values: row.map(String) } };
    // Repeated headers stay in the exact raw snapshot, never collapsed into one editable value.
    out.customFields = Object.fromEntries(customColumns.map(({key,index}) => [key, String(row[index] ?? "")]));
    for (const field of ["issueType", "status", "priority", "epicKey", "epicName", "project"]) {
      const value = cell(row, field);
      if (value) out[field] = value;
    }
    out.statusCategory = cell(row, "statusCategory") || statusCategory(out.status);
    if (!out.statusCategory) delete out.statusCategory;
    if (map.description >= 0) out.description = cell(row, "description");
    if (map.dueDate >= 0) {
      const raw = cell(row, "dueDate");
      const date = parseJiraDate(raw);
      if (!raw || date) out.dueDate = date;
      else skipped.push(`Row ${i + 2}: invalid due date "${raw}"; existing date kept.`);
    }
    if (map.epicKey >= 0 && !cell(row, "epicKey")) out.epicKey = "";
    const updated = parseJiraDateTime(cell(row, "updated"));
    if (updated) out.updated = updated;
    if (map.assignee >= 0) {
      out.assigneeJiraId = findPerson(cell(row, "assignee"));
      if (out.assigneeJiraId && !people.some((p) => p.jiraId === out.assigneeJiraId)) out.unresolvedAssignee = cell(row, "assignee");
    }
    out.project ||= out.key.replace(/-\d+$/, "");
    if (out.epicKey && !/^[A-Z][A-Z0-9_]*-\d+$/i.test(out.epicKey)) delete out.epicKey;
    rows.push(out);
  });
  return { rows, skipped, columns: map };
}

/** Lossless snapshot export, including duplicate headers (comments, labels, etc.). */
export function rawExportCSV(tickets) {
  const identities = [], headers = [];
  const snapshots = tickets.map((t) => {
    if (!t.raw?.headers || !t.raw?.values) throw new Error(`${t.atlasId || t.id}: no imported raw snapshot.`);
    const seen = new Map();
    return t.raw.headers.map((header, i) => {
      const occurrence = seen.get(header) || 0;
      seen.set(header, occurrence + 1);
      const identity = JSON.stringify([header, occurrence]);
      if (!identities.includes(identity)) { identities.push(identity); headers.push(header); }
      return [identity, t.raw.values[i] ?? ""];
    });
  });
  const rows = snapshots.map((cells) => {
    const values = new Map(cells);
    return identities.map((id) => values.get(id) ?? "");
  });
  return { headers, rows, csv: csvText(headers, rows) };
}

/** Review only: authoritative matching/version checks also run on the server. */
export function reviewImportRows(rows, tickets, people) {
  const norm = (v) => String(v || "").trim().replace(/\s+/g, " ").toLowerCase();
  return rows.map((row) => {
    const existing = tickets.find((t) => t.jiraKey?.toUpperCase() === row.key);
    const project = row.project || row.key.replace(/-\d+$/, "");
    const candidates = existing ? [] : tickets.filter((t) => !t.jiraKey && ["Draft", "Exported"].includes(t.stage) &&
      norm(t.projectKey) === norm(project) && norm(t.summary) === norm(row.summary) && norm(t.issueType || "Task") === norm(row.issueType || "Task"));
    const selected = existing || (candidates.length === 1 ? candidates[0] : null);
    return { ...row, candidates, resolution: existing ? "key" : selected ? selected.id : candidates.length ? "" : "new",
      expectedVersion: selected?.version, needsMatch: candidates.length > 1,
      needsAssignee: !!row.assigneeJiraId && !people.some((p) => p.jiraId === row.assigneeJiraId),
      assigneeResolution: "", assigneeId: "" };
  });
}

/** Plain text a person pastes into Jira for one pending update. */
export function updateText(update) {
  if (update.status && update.status !== "pending") return "";
  const pending = (status) => !status || status === "pending";
  const lines = [];
  for (const [field, value] of Object.entries(update.changes || {})) {
    if (field === "assignee" && Object.hasOwn(update.changes, "assigneeId")) continue;
    if (!pending(update.fieldStatus?.[field])) continue;
    if (field === "assigneeId" || field === "assignee") {
      lines.push(`assignee: ${value == null || value === "" ? "Unassign (clear the assignee in Jira)" : update.assigneeLabel || update.changes.assignee || value}`);
    } else lines.push(`${field}: ${value ?? "(clear it)"}`);
  }
  const comments = (update.comments || []).filter((c) => typeof c === "string" || pending(c.status));
  return [
    lines.length ? "Change in Jira:\n" + lines.join("\n") : "",
    comments.length ? "Comment:\n" + comments.map((c) => typeof c === "string" ? c : c.text + (c.mentions?.length ? `\nSelect mentions in Jira: ${c.mentions.map((m) => m.alias || m.name || m.userId).join(", ")}` : "")).join("\n\n") : "",
  ]
    .filter(Boolean)
    .join("\n\n");
}
