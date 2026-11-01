import { indexForSuggestions } from "./suggestions.js";
import { parse } from "@babel/parser";
import { DOMParser } from "@xmldom/xmldom";
import { analyzeObject } from "./metadata.js";
import { evidenceKind } from "./recipes.js";
import { apexSnippets, jsSnippets } from "./snippets.js";
const uniq = (a) => Array.from(new Set(a));
function jsImports(f) {
  let ast;
  try {
    ast = parse(f.text, {
      sourceType: "unambiguous",
      errorRecovery: true,
      plugins: ["decorators-legacy", "typescript"],
      createImportExpressions: true,
    });
  } catch {
    f.facts.push(
      "JavaScript import analysis unavailable: syntax could not be parsed",
    );
    return;
  }
  f.snippets = jsSnippets(ast, f.text);
  const pending = [ast];
  while (pending.length) {
    const node = pending.pop();
    if (!node || typeof node !== "object") continue;
    const source = [
      "ImportDeclaration",
      "ExportNamedDeclaration",
      "ExportAllDeclaration",
      "ImportExpression",
    ].includes(node.type)
      ? node.source
      : null;
    if (source?.type === "StringLiteral") {
      const value = source.value,
        line = node.loc.start.line;
      let kind,
        target,
        detail = "";
      if (value.startsWith("@salesforce/apex/")) {
        detail = value.slice(17);
        kind = "Apex import";
        target = detail.split(".").slice(0, -1).join(".");
      } else if (value.startsWith("c/")) {
        kind = "LWC module";
        target = value.slice(2);
      } else if (value.startsWith("@salesforce/schema/"))
        f.objects.push(value.slice(19));
      if (kind && target)
        f.refs.push({ kind, target, line, detail, confidence: "Direct" });
    }
    for (const [key, value] of Object.entries(node)) {
      if (["loc", "comments", "tokens", "errors"].includes(key)) continue;
      if (Array.isArray(value)) pending.push(...value);
      else if (value && typeof value === "object") pending.push(value);
    }
  }
}
function stripComments(text, html = false) {
  return html
    ? text.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, " "))
    : text.replace(
        /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(\/\*[\s\S]*?\*\/|\/\/[^\n]*)/g,
        (m, string) => string || m.replace(/[^\n]/g, " "),
      );
}
const lineIndexes = new Map();
function lineAt(text, index) {
  let offsets = lineIndexes.get(text);
  if (!offsets) {
    offsets = [0];
    for (let i = 0; i < text.length; i++)
      if (text.charCodeAt(i) === 10) offsets.push(i + 1);
    if (lineIndexes.size >= 2)
      lineIndexes.delete(lineIndexes.keys().next().value);
    lineIndexes.set(text, offsets);
  }
  let low = 0,
    high = offsets.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (offsets[mid] <= index) low = mid + 1;
    else high = mid;
  }
  return Math.max(1, low);
}
function matches(text, re, fn) {
  for (const m of text.matchAll(re)) fn(m);
}
function analyze(f) {
  const t = f.text,
    lower = f.path.toLowerCase(),
    clean = stripComments(t, /\.(html|xml|flow)$/i.test(lower));
  const lwcIndex = f.path
    .split("/")
    .findIndex((x) => x.toLowerCase() === "lwc");
  const isFlow =
    /\.flow(?:-meta\.xml)?$/i.test(lower) ||
    (/\.(xml|flow)$/i.test(lower) && /<(?:\w+:)?Flow[\s>]/.test(t));
  if (lwcIndex >= 0 && lwcIndex < f.path.split("/").length - 2) f.type = "LWC";
  else if (/\.(cls|trigger)(-meta\.xml)?$/i.test(lower)) f.type = "Apex";
  else if (isFlow) f.type = "Flow";
  else if (/\.(js|ts)$/i.test(lower) && /\bLightningElement\b/.test(clean))
    f.type = "LWC";
  const ref = (kind, target, m, detail = "", confidence = "Direct") =>
    f.refs.push({
      kind,
      target,
      line: m ? lineAt(clean, m.index) : 1,
      detail,
      confidence,
    });
  if (f.type === "LWC" || /\.(js|ts|html)$/i.test(lower)) {
    if (/\.(js|ts)$/i.test(lower)) jsImports(f);
    matches(clean, /<c-([a-z0-9-]+)(?=[\s/>])/g, (m) =>
      ref(
        "Renders LWC",
        m[1].replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase()),
        m,
      ),
    );
    matches(
      clean,
      /(?:flow-api-name\s*=\s*['"]|\.startFlow\(\s*['"])([\w]+)['"]/g,
      (m) => ref("Starts Flow", m[1], m),
    );
    matches(clean, /new\s+CustomEvent\(\s*['"]([^'"]+)['"]/g, (m) =>
      f.events.push(m[1]),
    );
    matches(clean, /@api\s+(?:get\s+|set\s+)?([\w$]+)/g, (m) =>
      f.symbols.push({
        name: m[1],
        kind: "Public API",
        line: lineAt(clean, m.index),
      }),
    );
    matches(clean, /@wire\(\s*([\w$]+)/g, (m) => f.facts.push(`Wires ${m[1]}`));
    if (/\bLightningElement\b/.test(clean))
      f.facts.push("Lightning web component controller");
    if (/\.html$/i.test(lower)) f.facts.push("Component template");
    if (/\.css$/i.test(lower)) f.facts.push("Component styles");
  }
  if (f.type === "Apex" && !/-meta\.xml$/i.test(lower)) {
    f.snippets = apexSnippets(t);
    const klass = clean.match(/\b(?:class|interface|enum|trigger)\s+(\w+)/);
    f.entityName = klass?.[1] || f.name.replace(/\.(cls|trigger)$/i, "");
    f.isTest = /@isTest\b|\btestMethod\b/i.test(clean);
    if (f.isTest) f.facts.push("Apex test source");
    if (/\bwith\s+sharing\b/.test(clean)) f.facts.push("Declared with sharing");
    if (/\bwithout\s+sharing\b/.test(clean))
      f.facts.push("Declared without sharing");
    if (/\binherited\s+sharing\b/.test(clean))
      f.facts.push("Declared inherited sharing");
    const aura = (clean.match(/@AuraEnabled\b/gi) || []).length,
      invocable = (clean.match(/@InvocableMethod\b/gi) || []).length;
    if (aura)
      f.facts.push(`${aura} @AuraEnabled annotation${aura === 1 ? "" : "s"}`);
    if (invocable)
      f.facts.push(
        `${invocable} @InvocableMethod annotation${invocable === 1 ? "" : "s"}`,
      );
    matches(
      clean,
      /\b(?:public|private|protected|global)\s+(?:(?:static|virtual|override|final|testMethod|abstract|webservice)\s+)*(?:[\w.]+(?:\s*<[^;{}()]+>)?(?:\[\])?\s+)(\w+)\s*\([^;{}]*?\)\s*(?:\{|;)/g,
      (m) =>
        f.symbols.push({
          name: m[1],
          kind: "Method",
          line: lineAt(clean, m.index),
        }),
    );
    matches(clean, /\b(?:FROM|JOIN)\s+([A-Za-z_]\w*)\b/gi, (m) =>
      f.objects.push(m[1]),
    );
    matches(clean, /\bSchema\.([A-Za-z_]\w*)\b/g, (m) => f.objects.push(m[1]));
    const trigger = clean.match(/\btrigger\s+\w+\s+on\s+(\w+)/i);
    if (trigger) f.objects.push(trigger[1]);
    matches(clean, /\b([A-Za-z_]\w*__(?:mdt|c|e))\s*\./g, (m) =>
      f.objects.push(m[1]),
    );
    const dml = uniq(
      (
        clean.match(/\b(insert|update|upsert|delete|undelete|merge)\b/gi) || []
      ).map((x) => x.toLowerCase()),
    );
    if (dml.length) f.facts.push("DML keywords: " + dml.join(", "));
    matches(clean, /\b(?:new\s+|extends\s+|implements\s+)([A-Z]\w*)\b/g, (m) =>
      ref("Apex reference", m[1], m, "Type usage", "Inferred"),
    );
    matches(clean, /\b([A-Z]\w*)\s*\.\s*\w+\s*\(/g, (m) =>
      ref("Apex reference", m[1], m, "Static-style call", "Inferred"),
    );
  }
  if (/\.(xml|flow|object)$/i.test(lower) || isFlow) {
    let doc,
      invalid = /<!DOCTYPE|<!ENTITY/i.test(t);
    try {
      if (!invalid)
        doc = new DOMParser({
          locator: {},
          errorHandler: {
            warning: () => {
              invalid = true;
            },
            error: () => {
              invalid = true;
            },
            fatalError: () => {
              invalid = true;
            },
          },
        }).parseFromString(t, "application/xml");
    } catch (e) {
      invalid = true;
    }
    if (doc?.documentElement && !invalid) {
      analyzeObject(f, doc);
      const all = (name, el = doc) =>
          Array.from(el.getElementsByTagName("*")).filter(
            (x) => x.localName === name,
          ),
        val = (name, el = doc) => all(name, el)[0]?.textContent?.trim() || "";
      const permissionRoot = doc.documentElement.localName;
      if (["PermissionSet", "Profile"].includes(permissionRoot)) {
        f.type = "Permission";
        f.entityName = f.name.replace(
          /\.(permissionset|profile)(-meta\.xml)?$/i,
          "",
        );
        f.label = val("label");
        f.facts.push(
          `${permissionRoot}: declarations only; not proof of effective access or assignment`,
        );
        for (const tag of ["object", "field"])
          for (const node of all(tag)) {
            const target = node.textContent.trim();
            if (target)
              f.refs.push({
                kind: "Permission schema",
                target,
                targetType: "Object",
                detail: target,
                line: node.lineNumber || 1,
                confidence: "Direct",
              });
          }
        for (const node of all("apexClass")) {
          const target = node.textContent.trim();
          if (target)
            f.refs.push({
              kind: "Permission Apex access",
              target,
              line: node.lineNumber || 1,
              confidence: "Direct",
            });
        }
      }
      if (f.type === "Flow") {
        f.entityName = f.name
          .replace(/\.flow(?:-meta\.xml)?$/i, "")
          .replace(/\.xml$/i, "");
        const rootVal = (name) =>
          Array.from(doc.documentElement.childNodes)
            .find((x) => x.localName === name)
            ?.textContent.trim() || "";
        f.label = rootVal("label");
        f.description = rootVal("description");
        for (const name of [
          "processType",
          "status",
          "triggerType",
          "recordTriggerType",
        ]) {
          const v = val(name);
          if (v) f.facts.push(`${name}: ${v}`);
        }
        for (const name of [
          "screens",
          "decisions",
          "assignments",
          "recordLookups",
          "recordCreates",
          "recordUpdates",
          "recordDeletes",
          "loops",
          "actionCalls",
          "subflows",
        ]) {
          const n = all(name).length;
          if (n) f.facts.push(`${n} ${name}`);
        }
        all("object").forEach((e) => f.objects.push(e.textContent.trim()));
        all("actionCalls").forEach((a) => {
          if (val("actionType", a) === "apex")
            f.refs.push({
              kind: "Flow Apex action",
              target: val("actionName", a),
              line: xmlLine(t, "actionName", val("actionName", a)),
              detail: val("label", a),
              confidence: "Direct",
            });
        });
        all("subflows").forEach((a) => {
          const target = val("flowName", a);
          if (target)
            f.refs.push({
              kind: "Subflow",
              target,
              line: xmlLine(t, "flowName", target),
              detail: val("label", a),
              confidence: "Direct",
            });
        });
        all("extensionName").forEach((a) => {
          const target = a.textContent.trim();
          if (target.startsWith("c:"))
            f.refs.push({
              kind: "Flow screen LWC",
              target: target.slice(2),
              line: xmlLine(t, "extensionName", target),
              detail: "Screen component",
              confidence: "Direct",
            });
        });
        all("variables").forEach((a) => {
          const v = val("name", a);
          if (v)
            f.symbols.push({
              name: v,
              kind: `${val("dataType", a)} variable${val("isInput", a) === "true" ? " · input" : ""}${val("isOutput", a) === "true" ? " · output" : ""}`,
              line: xmlLine(t, "name", v),
            });
        });
      } else if (f.type === "LWC") {
        f.description = val("description");
        if (val("isExposed")) f.facts.push("Exposed: " + val("isExposed"));
        all("target").forEach((x) => f.facts.push(x.textContent.trim()));
      }
    } else if (t.trim())
      f.facts.push("XML could not be parsed; check source syntax");
  }
  if (!f.description) {
    const d = t.match(/(?:Description\s*[:\-]\s*|@description\s+)([^\r\n]+)/i);
    if (d) f.description = d[1].replace(/\*\/$/, "").trim();
  }
  const evidence = evidenceKind(f.path);
  if (f.type === "Other" && evidence) {
    f.type = "Evidence";
    f.evidenceKind = evidence;
    f.facts.push(evidence + "; local text, not executed or rendered");
  }
  if (/\.(test|spec)\.[jt]s$/i.test(f.path) || /\/__tests__\//.test(f.path))
    f.isTest = true;
  f.objects = uniq(f.objects).filter(Boolean);
  if (f.type !== "Object")
    for (const target of f.objects) {
      const i = t.indexOf(target);
      f.refs.push({
        kind: "Schema reference",
        target,
        targetType: "Object",
        line: lineAt(t, Math.max(0, i)),
        detail: target,
        confidence: f.type === "Apex" ? "Inferred" : "Direct",
      });
    }
  f.events = uniq(f.events);
  f.facts = uniq(f.facts);
  f.refs = f.refs.filter((x) => x.target);
  indexForSuggestions(f);
}
function xmlLine(text, tag, value) {
  const index = text.indexOf(`<${tag}>${value}</${tag}>`);
  return index < 0 ? 1 : lineAt(text, index);
}

export { analyze, lineAt };
