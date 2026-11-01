import { parseAgentJSON } from "./agent-response.js";
import ExcelJS from "exceljs";
import PptxGenJS from "pptxgenjs";
import {
  Document,
  CheckBox,
  Packer,
  Paragraph,
  TextRun,
  Tab,
  TabStopType,
  HeadingLevel,
  Table,
  TableRow,
  TableCell,
  WidthType,
  LevelFormat,
  AlignmentType,
  ShadingType,
} from "docx";

export const htmlEscape = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const xmlControls = /[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]/;
function fail(message) {
  throw Error(message);
}
function object(v, keys, label) {
  if (
    !v ||
    Array.isArray(v) ||
    typeof v !== "object" ||
    Object.keys(v).some((k) => !keys.includes(k))
  )
    fail(`${label}: unsupported fields or invalid object.`);
}
function text(v, label, max = 20000) {
  if (
    typeof v !== "string" ||
    !v.trim() ||
    v.length > max ||
    xmlControls.test(v)
  )
    fail(
      `${label}: expected nonempty text, at most ${max} characters, no XML control characters.`,
    );
  return v;
}
function list(v, label, max = 500, min = 1) {
  if (!Array.isArray(v) || v.length < min || v.length > max)
    fail(`${label}: expected ${min}–${max} entries.`);
  return v;
}
export function safeOutputName(name) {
  text(name, "Filename", 120);
  if (
    /[\\/:*?"<>|\x00-\x1f]/.test(name) ||
    /^\./.test(name) ||
    /[. ]$/.test(name) ||
    name !== name.trim() ||
    /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)
  )
    fail("Use a safe filename only, not a path, URL or reserved device name.");
  return name;
}
function validateBlocks(blocks, kind) {
  return list(blocks, "blocks").map((b) => {
    object(
      b,
      ["type", "text", "level", "runs", "items", "headers", "rows"],
      "Block",
    );
    if (
      ![
        "heading",
        "paragraph",
        "bullets",
        "numbered",
        "checklist",
        "table",
      ].includes(b.type)
    )
      fail(
        "Supported blocks: heading, paragraph, bullets, numbered, checklist (Word only), table.",
      );
    const keys = {
      heading: ["type", "text", "level"],
      paragraph: ["type", "text", "runs"],
      bullets: ["type", "items"],
      numbered: ["type", "items"],
      checklist: ["type", "items"],
      table: ["type", "headers", "rows"],
    }[b.type];
    object(b, keys, b.type);
    if (b.type === "heading") {
      text(b.text, "Heading", 300);
      if (b.level !== undefined && ![1, 2, 3].includes(b.level))
        fail("Heading level must be 1, 2 or 3.");
    }
    if (b.type === "paragraph") {
      if ((b.text !== undefined) === (b.runs !== undefined))
        fail("Paragraph needs text OR runs.");
      if (b.text !== undefined) text(b.text, "Paragraph");
      else
        list(b.runs, "runs", 100).forEach((r) => {
          object(r, ["text", "bold", "italic", "underline"], "Run");
          text(r.text, "Run");
          for (const k of ["bold", "italic", "underline"])
            if (r[k] !== undefined && typeof r[k] !== "boolean")
              fail(`${k} must be boolean.`);
        });
    }
    if (["bullets", "numbered"].includes(b.type))
      list(b.items, "List items", 200).forEach((t) =>
        text(t, "List item", 4000),
      );
    if (b.type === "checklist") {
      if (kind !== "docx")
        fail("Checklist blocks are supported only in Word documents.");
      for (const item of list(b.items, "Checklist items", 200)) {
        object(item, ["text", "checked"], "Checklist item");
        text(item.text, "Checklist item text", 4000);
        if (item.checked !== undefined && typeof item.checked !== "boolean")
          fail("Checklist checked must be boolean.");
      }
    }
    if (b.type === "table") {
      list(b.headers, "Table headers", 12).forEach((t) =>
        text(t, "Header", 300),
      );
      list(b.rows, "Table rows", 200).forEach((row) => {
        if (!Array.isArray(row) || row.length !== b.headers.length)
          fail("Table rows must match header width.");
        row.forEach((t) => {
          if (typeof t !== "string" || t.length > 4000 || xmlControls.test(t))
            fail("Table cells must be text of at most 4,000 characters.");
        });
      });
    }
    return b;
  });
}
export function validateFileResult(raw, requestId) {
  if (typeof raw === "string") {
    if (raw.length > 5 * 1024 * 1024)
      fail("Final JSON exceeds 5 MB. Split the work into smaller requests.");
    raw = parseAgentJSON(raw);
  }
  object(raw, ["type", "version", "requestId", "artifacts"], "Final response");
  if (
    raw.type !== "atlas-files" ||
    raw.version !== 1 ||
    raw.requestId !== requestId
  )
    fail(
      "Use atlas-files, version 1, and the current requestId from the prompt.",
    );
  const names = new Set();
  list(raw.artifacts, "artifacts", 20).forEach((a) => {
    const keys = {
      docx: ["kind", "name", "title", "blocks"],
      email: ["kind", "name", "subject", "blocks"],
      xlsx: ["kind", "name", "sheets"],
      pptx: ["kind", "name", "title", "slides"],
    }[a?.kind];
    if (!keys) fail("Supported artifact kinds: docx, xlsx, pptx, email.");
    object(a, keys, "Artifact");
    safeOutputName(a.name);
    if (
      !a.name
        .toLowerCase()
        .endsWith("." + (a.kind === "email" ? "eml" : a.kind))
    )
      fail("Filename extension must match kind (.eml for email).");
    if (names.has(a.name.toLowerCase())) fail("Duplicate output filename.");
    names.add(a.name.toLowerCase());
    if (a.title !== undefined) text(a.title, "Title", 200);
    if (["docx", "email"].includes(a.kind)) validateBlocks(a.blocks, a.kind);
    if (a.kind === "email") {
      text(a.subject, "Email subject", 200);
      if (/[\r\n]/.test(a.subject)) fail("Email subject must be one line.");
    }
    if (a.kind === "xlsx") {
      const sheetNames = new Set();
      let cells = 0;
      list(a.sheets, "sheets", 30).forEach((s) => {
        object(s, ["name", "rows"], "Sheet");
        text(s.name, "Sheet name", 31);
        if (
          /[\\/\[\]:*?]/.test(s.name) ||
          s.name.startsWith("'") ||
          s.name.endsWith("'") ||
          sheetNames.has(s.name.toLowerCase())
        )
          fail("Sheet names must be unique and valid Excel names.");
        sheetNames.add(s.name.toLowerCase());
        list(s.rows, "Sheet rows", 10000).forEach((row) => {
          list(row, "Row cells", 100);
          cells += row.length;
          row.forEach((v) => {
            if (
              v === null ||
              typeof v === "boolean" ||
              (typeof v === "number" && Number.isFinite(v))
            )
              return;
            if (
              typeof v === "string" &&
              v.length <= 32767 &&
              !xmlControls.test(v)
            )
              return;
            fail(
              "Cells must be text, finite numbers, booleans or null; formulas and external links are not generated.",
            );
          });
        });
        if (cells > 100000) fail("Workbook exceeds 100,000 cells.");
      });
    }
    if (a.kind === "pptx")
      list(a.slides, "slides", 100).forEach((s) => {
        object(s, ["title", "body", "bullets", "notes"], "Slide");
        text(s.title, "Slide title", 100);
        if (s.body !== undefined) text(s.body, "Slide body", 600);
        if (s.bullets !== undefined)
          list(s.bullets, "Slide bullets", 6).forEach((t) =>
            text(t, "Slide bullet", 160),
          );
        if (s.body && s.bullets)
          fail("A slide may have body OR bullets, not both.");
        if (s.notes !== undefined) text(s.notes, "Speaker notes", 20000);
      });
  });
  return structuredClone(raw);
}
export function blockText(b) {
  if (b.type === "paragraph")
    return b.text ?? b.runs.map((r) => r.text).join("");
  if (b.type === "heading") return b.text;
  if (b.type === "checklist")
    return b.items
      .map((item) => `${item.checked ? "[x]" : "[ ]"} ${item.text}`)
      .join("\n");
  if (b.type === "table")
    return [b.headers, ...b.rows].map((r) => r.join(" | ")).join("\n");
  return b.items
    .map((t, i) => (b.type === "numbered" ? `${i + 1}. ` : "• ") + t)
    .join("\n");
}
const inline = (t) => htmlEscape(t).replace(/\r?\n/g, "<br>");
export function blocksHTML(blocks) {
  return blocks
    .map((b) => {
      if (b.type === "heading") {
        const level = b.level || 2;
        return `<h${level} style="font-family:Arial,sans-serif;color:#172b3a;margin:18px 0 8px">${inline(b.text)}</h${level}>`;
      }
      if (b.type === "paragraph")
        return `<p style="margin:0 0 12px;line-height:1.5">${
          b.text !== undefined
            ? inline(b.text)
            : b.runs
                .map((r) => {
                  let s = inline(r.text);
                  if (r.bold) s = "<strong>" + s + "</strong>";
                  if (r.italic) s = "<em>" + s + "</em>";
                  if (r.underline) s = "<u>" + s + "</u>";
                  return s;
                })
                .join("")
        }</p>`;
      if (b.type === "table")
        return `<table style="border-collapse:collapse;width:100%;margin:12px 0"><thead><tr>${b.headers.map((c) => `<th style="border:1px solid #b8c2cc;background:#edf2f5;padding:8px;text-align:left">${inline(c)}</th>`).join("")}</tr></thead><tbody>${b.rows.map((r) => "<tr>" + r.map((c) => `<td style="border:1px solid #b8c2cc;padding:8px;vertical-align:top">${inline(c)}</td>`).join("") + "</tr>").join("")}</tbody></table>`;
      if (b.type === "checklist")
        return `<ul style="list-style:none;margin:8px 0 16px;padding-left:26px">${b.items.map((item) => `<li style="margin:5px 0"><span role="img" aria-label="${item.checked ? "Checked" : "Unchecked"}">${item.checked ? "☒" : "☐"}</span> ${inline(item.text)}</li>`).join("")}</ul>`;
      const tag = b.type === "numbered" ? "ol" : "ul";
      return `<${tag} style="margin:8px 0 16px;padding-left:26px">${b.items.map((t) => `<li style="margin:5px 0">${inline(t)}</li>`).join("")}</${tag}>`;
    })
    .join("");
}
export function artifactPreview(a) {
  let body;
  if (a.kind === "xlsx")
    body = a.sheets
      .map((s) => {
        const width = Math.max(...s.rows.map((r) => r.length));
        const count = Math.min(
          s.rows.length,
          100,
          Math.max(1, Math.floor(3000 / (a.sheets.length * width))),
        );
        const rows = s.rows
          .slice(0, count)
          .map((r) =>
            Array.from({ length: width }, (_, i) => String(r[i] ?? "")),
          );
        return (
          `<h2>${htmlEscape(s.name)}</h2><p>${s.rows.length} rows. Values only; first row is styled as a header. No formulas run.</p>${count < s.rows.length ? `<p><strong>Preview shows the first ${count} rows only.</strong> All ${s.rows.length} rows remain in the Agent JSON for review and are included in the saved workbook.</p>` : ""}` +
          blocksHTML([{ type: "table", headers: rows[0], rows: rows.slice(1) }])
        );
      })
      .join("");
  else if (a.kind === "pptx")
    body = a.slides
      .map(
        (s, i) =>
          `<section style="border:1px solid #b8c2cc;border-radius:12px;padding:24px;margin-bottom:20px"><small>Slide ${i + 1}</small><h2>${htmlEscape(s.title)}</h2>${s.body ? "<p>" + inline(s.body) + "</p>" : s.bullets ? blocksHTML([{ type: "bullets", items: s.bullets }]) : ""}${s.notes ? "<details><summary>Speaker notes</summary><p>" + inline(s.notes) + "</p></details>" : ""}</section>`,
      )
      .join("");
  else
    body =
      (a.kind === "email"
        ? "<p><strong>Subject:</strong> " + htmlEscape(a.subject) + "</p>"
        : "") + blocksHTML(a.blocks);
  return `<div style="font-family:Arial,sans-serif;font-size:14px;color:#172b3a;background:white;padding:24px;overflow-wrap:anywhere">${body}</div>`;
}
export function emailHTML(a) {
  return `<div style="font-family:Arial,sans-serif;font-size:11pt;color:#172b3a;line-height:1.5">${blocksHTML(a.blocks)}</div>`;
}
export function emailText(a) {
  return a.blocks.map(blockText).join("\n\n");
}
function wordRuns(runs) {
  return runs.flatMap((r) =>
    r.text
      .replace(/\r\n?/g, "\n")
      .split("\n")
      .map(
        (text, i) =>
          new TextRun({
            text,
            bold: r.bold,
            italics: r.italic,
            underline: r.underline ? {} : undefined,
            break: i ? 1 : undefined,
          }),
      ),
  );
}
// docx 9.9 exposes checkbox states but no content-control ID option. Extend
// its serialization hook, leaving the actual checkbox markup to the library.
class IdentifiedCheckBox extends CheckBox {
  constructor(id, options) {
    super(options);
    this.controlId = id;
  }
  prepForXml(context) {
    const xml = super.prepForXml(context);
    const properties = xml["w:sdt"].find((child) => child["w:sdtPr"])[
      "w:sdtPr"
    ];
    // OOXML orders alias before id, and id before the checkbox properties.
    properties.splice(
      properties.findIndex((child) => child["w14:checkbox"]),
      0,
      { "w:id": { _attr: { "w:val": this.controlId } } },
    );
    return xml;
  }
}
async function wordBytes(a) {
  let listIndex = 0;
  let checkboxId = 0;
  const configs = [];
  const children = a.blocks.flatMap((b) => {
    if (b.type === "heading")
      return [
        new Paragraph({
          text: b.text,
          heading: HeadingLevel["HEADING_" + (b.level || 2)],
        }),
      ];
    if (b.type === "paragraph")
      return [
        new Paragraph({
          children: wordRuns(b.runs || [{ text: b.text }]),
          spacing: { after: 160 },
        }),
      ];
    if (b.type === "table") {
      const widths = b.headers.map(() => Math.floor(9360 / b.headers.length));
      widths[widths.length - 1] += 9360 - widths.reduce((s, n) => s + n, 0);
      return [
        new Table({
          width: { size: 9360, type: WidthType.DXA },
          columnWidths: widths,
          rows: [b.headers, ...b.rows].map(
            (r, i) =>
              new TableRow({
                tableHeader: i === 0,
                children: r.map(
                  (t, j) =>
                    new TableCell({
                      width: { size: widths[j], type: WidthType.DXA },
                      shading:
                        i === 0
                          ? { type: ShadingType.CLEAR, fill: "EDF2F5" }
                          : undefined,
                      children: [
                        new Paragraph({
                          children: wordRuns([{ text: t, bold: i === 0 }]),
                        }),
                      ],
                    }),
                ),
              }),
          ),
        }),
        new Paragraph(""),
      ];
    }
    if (b.type === "checklist")
      return b.items.map(
        (item) =>
          new Paragraph({
            children: [
              new IdentifiedCheckBox(++checkboxId, {
                checked: item.checked ?? false,
                alias: `Checklist item ${checkboxId}`,
                checkedState: { value: "2612", font: "Arial" },
                uncheckedState: { value: "2610", font: "Arial" },
              }),
              new TextRun({ children: [new Tab()] }),
              ...wordRuns([{ text: item.text }]),
            ],
            indent: { left: 360, hanging: 360 },
            tabStops: [{ type: TabStopType.LEFT, position: 360 }],
            spacing: { after: 100 },
          }),
      );
    const reference = "list-" + listIndex++;
    configs.push({
      reference,
      levels: [
        {
          level: 0,
          format:
            b.type === "numbered" ? LevelFormat.DECIMAL : LevelFormat.BULLET,
          text: b.type === "numbered" ? "%1." : "•",
          alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } },
        },
      ],
    });
    return b.items.map(
      (t) =>
        new Paragraph({
          children: wordRuns([{ text: t }]),
          numbering: { reference, level: 0 },
          spacing: { after: 100 },
        }),
    );
  });
  const doc = new Document({
    creator: "Atlas (offline)",
    title: a.title || a.name,
    styles: {
      default: {
        document: {
          run: { font: "Arial", size: 22 },
          paragraph: { spacing: { after: 160 } },
        },
      },
    },
    numbering: { config: configs },
    sections: [
      {
        properties: {
          page: {
            size: { width: 12240, height: 15840 },
            margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 },
          },
        },
        children,
      },
    ],
  });
  return new Uint8Array(await (await Packer.toBlob(doc)).arrayBuffer());
}
async function spreadsheetBytes(a) {
  const wb = new ExcelJS.Workbook();
  wb.creator = "Atlas (offline)";
  for (const spec of a.sheets) {
    const ws = wb.addWorksheet(spec.name, {
      views: [{ state: "frozen", ySplit: 1 }],
    });
    spec.rows.forEach((r) => ws.addRow(r));
    const width = Math.max(...spec.rows.map((r) => r.length));
    for (let c = 1; c <= width; c++)
      ws.getColumn(c).width = Math.min(
        48,
        Math.max(
          14,
          ...spec.rows
            .slice(0, 200)
            .map((r) => String(r[c - 1] ?? "").length + 2),
        ),
      );
    ws.eachRow((r, i) => {
      r.eachCell((cell) => {
        cell.font = {
          name: "Arial",
          size: 11,
          bold: i === 1,
          color: { argb: "FF172B3A" },
        };
        cell.alignment = { vertical: "top", wrapText: true };
        if (i === 1)
          cell.fill = {
            type: "pattern",
            pattern: "solid",
            fgColor: { argb: "FFEDF2F5" },
          };
      });
    });
    ws.autoFilter = {
      from: { row: 1, column: 1 },
      to: { row: spec.rows.length, column: width },
    };
  }
  return new Uint8Array(await wb.xlsx.writeBuffer());
}
async function slidesBytes(a) {
  const pptx = new PptxGenJS();
  pptx.layout = "LAYOUT_WIDE";
  pptx.author = "Atlas (offline)";
  pptx.title = a.title || a.name;
  pptx.subject = "Generated locally from reviewed JSON";
  pptx.lang = "en-US";
  pptx.theme = { headFontFace: "Arial", bodyFontFace: "Arial", lang: "en-US" };
  a.slides.forEach((s, i) => {
    const slide = pptx.addSlide();
    const dark = i === 0;
    const ink = dark ? "FFFFFF" : "172B3A";
    slide.background = { color: dark ? "172B3A" : "FFFFFF" };
    slide.addText(s.title, {
      x: 0.6,
      y: 0.55,
      w: 12.1,
      h: 1.1,
      fontFace: "Arial",
      fontSize: 30,
      bold: true,
      color: ink,
      margin: 0,
      breakLine: false,
      fit: "shrink",
    });
    if (s.body)
      slide.addText(s.body, {
        x: 0.65,
        y: 2,
        w: 11.95,
        h: 4.3,
        fontSize: 22,
        fontFace: "Arial",
        color: ink,
        margin: 0,
        fit: "shrink",
        valign: "top",
        paraSpaceAfter: 12,
      });
    if (s.bullets) {
      const runs = s.bullets.map((t, j) => ({
        text: t,
        options: {
          bullet: { indent: 22 },
          hanging: 4,
          breakLine: j < s.bullets.length - 1,
        },
      }));
      slide.addText(runs, {
        x: 0.65,
        y: 2,
        w: 11.95,
        h: 4.3,
        fontSize: 20,
        fontFace: "Arial",
        color: ink,
        margin: 0,
        fit: "shrink",
        valign: "top",
        paraSpaceAfter: 16,
      });
    }
    slide.addText(String(i + 1), {
      x: 11.85,
      y: 6.7,
      w: 0.8,
      h: 0.3,
      fontSize: 11,
      color: dark ? "CAD6DE" : "657684",
      align: "right",
      margin: 0,
    });
    if (s.notes) slide.addNotes(s.notes);
  });
  return new Uint8Array(
    await pptx.write({ outputType: "arraybuffer", compression: true }),
  );
}
function base64(text) {
  return btoa(
    Array.from(new TextEncoder().encode(text), (b) =>
      String.fromCharCode(b),
    ).join(""),
  );
}
function emailBytes(a) {
  const boundary = "atlas-" + crypto.randomUUID();
  const subject = Array.from(a.subject)
    .reduce((parts, c) => {
      if (
        !parts.length ||
        new TextEncoder().encode(parts.at(-1) + c).length > 42
      )
        parts.push(c);
      else parts[parts.length - 1] += c;
      return parts;
    }, [])
    .map((s) => "=?UTF-8?B?" + base64(s) + "?=")
    .join("\r\n ");
  const part = (mime, text) =>
    `--${boundary}\r\nContent-Type: ${mime}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${
      base64(text)
        .match(/.{1,76}/g)
        ?.join("\r\n") || ""
    }\r\n`;
  return new TextEncoder().encode(
    `X-Unsent: 1\r\nSubject: ${subject}\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary="${boundary}"\r\n\r\n${part("text/plain", emailText(a))}${part("text/html", emailHTML(a))}--${boundary}--\r\n`,
  );
}
export async function generateArtifact(a) {
  // Revalidate even a restored recipe before passing it to third-party writers.
  validateFileResult(
    { type: "atlas-files", version: 1, requestId: "render", artifacts: [a] },
    "render",
  );
  if (a.kind === "docx")
    return {
      bytes: await wordBytes(a),
      mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    };
  if (a.kind === "xlsx")
    return {
      bytes: await spreadsheetBytes(a),
      mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    };
  if (a.kind === "pptx")
    return {
      bytes: await slidesBytes(a),
      mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    };
  if (a.kind === "email")
    return { bytes: emailBytes(a), mime: "message/rfc822" };
  fail("Unsupported output kind.");
}
