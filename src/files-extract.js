import PostalMime from "postal-mime";
import MsgReaderModule from "@kenjiuno/msgreader";
import { parseDocument } from "htmlparser2";
import { unzipSync, strFromU8 } from "fflate";
import { DOMParser } from "@xmldom/xmldom";

const MAX_XML = 12 * 1024 * 1024,
  MAX_EXPANDED = 40 * 1024 * 1024;
export function readOfficeZip(bytes) {
  let size = 0,
    count = 0;
  return unzipSync(bytes, {
    filter(entry) {
      if (++count > 10000) throw Error("Archive has too many entries.");
      if (!/\.(xml|rels)$/i.test(entry.name)) return false;
      size += entry.originalSize;
      if (entry.originalSize > MAX_XML || size > MAX_EXPANDED)
        throw Error("Expanded XML exceeds the safe extraction limit.");
      if (
        entry.name.split("/").some((p) => p === "..") ||
        entry.name.startsWith("/")
      )
        throw Error("Unsafe archive path.");
      return true;
    },
  });
}
function parseXML(text) {
  if (/<!DOCTYPE|<!ENTITY/i.test(text))
    throw Error("DTD/entity declarations are not supported.");
  let bad = false;
  const doc = new DOMParser({
    errorHandler: {
      warning() {
        bad = true;
      },
      error() {
        bad = true;
      },
      fatalError() {
        bad = true;
      },
    },
  }).parseFromString(text, "application/xml");
  if (bad || !doc.documentElement) throw Error("Malformed document XML.");
  return doc;
}
const nodes = (doc, name) => Array.from(doc.getElementsByTagNameNS("*", name));
function zipXML(zip, path) {
  if (!zip[path]) throw Error("Missing Office part: " + path);
  return parseXML(strFromU8(zip[path]));
}
function wordText(node) {
  if (node.nodeType === 1) {
    if (["del", "instrText"].includes(node.localName)) return "";
    if (node.localName === "t") return node.textContent;
    if (node.localName === "tr")
      return (
        Array.from(node.childNodes || [])
          .filter((n) => n.localName === "tc")
          .map((n) => wordText(n).trim().replace(/\n/g, " / "))
          .join(" | ") + "\n"
      );
    if (node.localName === "tab") return "\t";
    if (node.localName === "br") return "\n";
  }
  const text = Array.from(node.childNodes || [])
    .map(wordText)
    .join("");
  return text + (node.localName === "p" ? "\n" : "");
}
function relation(zip, base, id) {
  const slash = base.lastIndexOf("/"),
    dir = base.slice(0, slash + 1),
    name = base.slice(slash + 1);
  const rels = zipXML(zip, dir + "_rels/" + name + ".rels");
  const r = nodes(rels, "Relationship").find(
    (n) => n.getAttribute("Id") === id,
  );
  if (!r || r.getAttribute("TargetMode") === "External")
    throw Error("Missing or external Office relationship.");
  const target = r.getAttribute("Target"),
    parts = [];
  for (const p of (target.startsWith("/")
    ? target.slice(1)
    : dir + target
  ).split("/")) {
    if (p === "..") {
      if (!parts.length) throw Error("Invalid Office relationship path.");
      parts.pop();
    } else if (p !== "." && p) parts.push(p);
  }
  return parts.join("/");
}
function richText(n) {
  return nodes(n, "t")
    .map((t) => t.textContent)
    .join("");
}
function slideText(doc) {
  return nodes(doc, "p")
    .map((p) => richText(p))
    .filter(Boolean)
    .join("\n");
}
export function htmlText(html) {
  const walk = (n) => {
    if (n.type === "text") return n.data;
    if (["script", "style", "iframe", "object", "svg", "head"].includes(n.name))
      return "";
    if (n.name === "br") return "\n";
    const value = (n.children || []).map(walk).join("");
    return (
      value +
      (["p", "div", "tr", "li", "h1", "h2", "h3", "blockquote"].includes(n.name)
        ? "\n"
        : n.name === "td" || n.name === "th"
          ? " | "
          : "")
    );
  };
  return walk(parseDocument(html))
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
export async function extractDocument(path, input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const result = {
    path,
    kind: "Other",
    state: "unavailable",
    sections: [],
    notice: "",
  };
  if (bytes.byteLength > 20 * 1024 * 1024)
    return { ...result, notice: "Over 20 MB; inventory only." };
  try {
    const ext = path.split(".").at(-1).toLowerCase();
    if (ext === "docx") {
      const zip = readOfficeZip(bytes);
      result.kind = "Word";
      result.sections = [
        {
          id: "body",
          label: "Document body",
          text: wordText(zipXML(zip, "word/document.xml")).trim(),
        },
      ];
      for (const part of Object.keys(zip)
        .filter((p) =>
          /^word\/(header\d+|footer\d+|footnotes|endnotes|comments)\.xml$/.test(
            p,
          ),
        )
        .sort())
        result.sections.push({
          id: part,
          label: part,
          text: wordText(zipXML(zip, part)).trim(),
        });
      result.notice =
        "Text and tables extracted; images, layout and embedded files are not read. Insertions included, deletions omitted; tracked-change history and formatting are not preserved. Generated documents are new files, not a round-trip edit.";
    } else if (ext === "xlsx") {
      result.kind = "Excel";
      const zip = readOfficeZip(bytes),
        wb = zipXML(zip, "xl/workbook.xml");
      const shared = zip["xl/sharedStrings.xml"]
        ? nodes(zipXML(zip, "xl/sharedStrings.xml"), "si").map(richText)
        : [];
      result.sections = nodes(wb, "sheet").map((sheet, i) => {
        const part = relation(
            zip,
            "xl/workbook.xml",
            sheet.getAttribute("r:id"),
          ),
          doc = zipXML(zip, part);
        const lines = nodes(doc, "c")
          .map((c) => {
            const address = c.getAttribute("r"),
              type = c.getAttribute("t"),
              v = nodes(c, "v")[0]?.textContent ?? "";
            const value =
              type === "s"
                ? (shared[Number(v)] ?? "[missing shared string]")
                : type === "inlineStr"
                  ? richText(c)
                  : type === "b"
                    ? v === "1"
                      ? "TRUE"
                      : "FALSE"
                    : v;
            const formula = nodes(c, "f")[0];
            if (!value && !formula) return "";
            return `${address}: ${JSON.stringify(value)}${formula ? ` [formula: ${formula.textContent || "shared/array formula; see anchor cell"}; cached result only]` : ""}`;
          })
          .filter(Boolean);
        return {
          id: "sheet-" + (i + 1),
          label:
            sheet.getAttribute("name") +
            (sheet.getAttribute("state")
              ? " [" + sheet.getAttribute("state") + "]"
              : ""),
          text: lines.join("\n") || "(No nonempty cells.)",
        };
      });
      result.notice =
        "Nonempty cells with coordinates and raw stored values (dates may be Excel serial numbers). Formulas are reported with possibly stale cached results, never evaluated. Hidden sheets included and labeled. Styles, charts, images and embedded files are not interpreted. Outputs create value tables, not formula/template round-trips.";
    } else if (ext === "pptx") {
      result.kind = "PowerPoint";
      const zip = readOfficeZip(bytes),
        pres = zipXML(zip, "ppt/presentation.xml");
      result.sections = nodes(pres, "sldId").map((s, i) => {
        const part = relation(
          zip,
          "ppt/presentation.xml",
          s.getAttribute("r:id"),
        );
        let text = slideText(zipXML(zip, part));
        const slash = part.lastIndexOf("/"),
          rels =
            part.slice(0, slash + 1) +
            "_rels/" +
            part.slice(slash + 1) +
            ".rels";
        if (zip[rels]) {
          const note = nodes(zipXML(zip, rels), "Relationship").find((n) =>
            /\/notesSlide$/.test(n.getAttribute("Type")),
          );
          if (note)
            text +=
              "\nSPEAKER NOTES\n" +
              slideText(
                zipXML(zip, relation(zip, part, note.getAttribute("Id"))),
              );
        }
        return {
          id: "slide-" + (i + 1),
          label: "Slide " + (i + 1),
          text: text || "(No extracted slide text.)",
        };
      });
      result.notice =
        "Slide text, table text and speaker notes in presentation order; XML reading order can differ from visual order. Images, charts, SmartArt, embedded files, animation and layout are not interpreted. Generated decks are new presentations, not template-preserving edits.";
    } else if (ext === "eml") {
      result.kind = "Outlook email";
      const mail = await PostalMime.parse(bytes, {
        maxNestingDepth: 30,
        maxHeadersSize: 1024 * 1024,
      });
      const address = (a) =>
        a ? [a.name, a.address].filter(Boolean).join(" ") : "";
      result.sections = [
        {
          id: "headers",
          label: "Email headers",
          text: `Subject: ${mail.subject || ""}\nFrom: ${address(mail.from)}\nTo: ${(mail.to || []).map(address).join("; ")}\nCc: ${(mail.cc || []).map(address).join("; ")}\nDate: ${mail.date || ""}`,
        },
        {
          id: "body",
          label: "Email body",
          text: mail.text || htmlText(mail.html || "") || "(No readable body.)",
        },
        {
          id: "attachments",
          label: "Attachment names only",
          text:
            (mail.attachments || [])
              .map((a) => `${a.filename || "(unnamed)"} (${a.mimeType})`)
              .join("\n") || "(No attachments.)",
        },
      ];
      result.notice =
        "Plain-text or sanitized HTML text. Attachments are listed, not extracted; save needed attachments separately in the files folder. Remote images/links are not loaded. Encrypted content cannot be read.";
    } else if (ext === "msg") {
      result.kind = "Outlook email";
      const Reader = MsgReaderModule.default || MsgReaderModule;
      const data = new Reader(
        bytes.buffer.slice(
          bytes.byteOffset,
          bytes.byteOffset + bytes.byteLength,
        ),
      ).getFileData();
      if (data.error) throw Error(data.error);
      const html =
        data.bodyHtml || (data.html ? new TextDecoder().decode(data.html) : "");
      result.sections = [
        {
          id: "headers",
          label: "Email headers",
          text: `Subject: ${data.subject || ""}\nFrom: ${data.senderName || ""} ${data.senderSmtpAddress || data.senderEmail || ""}\nRecipients: ${(data.recipients || []).map((r) => [r.name, r.smtpAddress || r.email].filter(Boolean).join(" ")).join("; ")}\nDate: ${data.messageDeliveryTime || data.clientSubmitTime || ""}`,
        },
        {
          id: "body",
          label: "Email body",
          text:
            data.body ||
            htmlText(html) ||
            "(Body unavailable: RTF-only, encrypted or unsupported message.)",
        },
        {
          id: "attachments",
          label: "Attachment names only",
          text:
            (data.attachments || [])
              .map(
                (a) =>
                  a.fileName ||
                  a.fileNameShort ||
                  a.name ||
                  "(unnamed attachment)",
              )
              .join("\n") || "(No attachments.)",
        },
      ];
      result.notice =
        "MSG plain-text/HTML bodies and headers only. RTF-only/encrypted bodies and attachment contents are not decoded; export as EML/text or save attachments separately. No Outlook connection, remote images or mail sending.";
    } else if (
      /^(txt|md|csv|tsv|json|jsonl|xml|yaml|yml|log|html|htm|js|ts|css|cls|sql)$/.test(
        ext,
      )
    ) {
      const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      if (text.includes("\0")) throw Error("Binary text is not supported.");
      result.kind = ["csv", "tsv"].includes(ext) ? "Table text" : "Text";
      result.sections = [
        {
          id: "body",
          label: "Text",
          text: /^html?$/.test(ext) ? htmlText(text) : text,
        },
      ];
      result.notice =
        "UTF-8 text; HTML is converted to text without executing or loading resources. CSV/TSV formulas are text only.";
    } else {
      result.notice = /^(doc|xls|ppt|xlsm|docm|pptm|pst|ost|pdf)$/.test(ext)
        ? "Unsupported legacy, macro-enabled, mailbox or PDF format. Export a non-macro DOCX/XLSX/PPTX, individual MSG/EML or UTF-8 text locally."
        : "Unsupported format; filename available, contents not extracted.";
      return result;
    }
    if (
      result.sections.reduce((n, s) => n + s.text.length, 0) >
      5 * 1024 * 1024
    )
      throw Error("Extracted text exceeds 5 MB per document.");
    result.state = "readable";
  } catch (e) {
    result.sections = [];
    result.notice = "Cannot extract: " + e.message;
  }
  return result;
}
