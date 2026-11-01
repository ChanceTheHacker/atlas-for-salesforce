// From API 67.0, Apex runs SOQL and DML as the running user. In a fresh org the
// administrator who deploys Atlas has no access to its fields until a permission set
// grants it, so test code that sets up or checks Atlas records as that administrator,
// outside System.runAs, fails there while passing in an org where the administrator
// already has access. That code must say `as system` or `WITH SYSTEM_MODE`, and must not
// reach such code through a test helper. This reads the real Apex tests.
import test from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

const classes = new URL("../salesforce/force-app/main/default/classes/", import.meta.url);
const names = (await readdir(classes)).filter((name) => /Test\.cls$|^Atlas_(Deployment)?Mock\.cls$/.test(name));

// Blank comments and string contents so their braces, semicolons and words don't count.
const strip = (text) => text.replace(/'(?:\\.|[^'\\\n])*'|\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, (found) =>
  found.startsWith("'") ? `'${"x".repeat(found.length - 2)}'` : found.replace(/[^\n]/g, " "));

// Each statement of a method body, and whether it runs inside System.runAs.
function statements(source, start) {
  const found = [];
  const blocks = [];
  let from = start;
  for (let i = start; i < source.length; i++) {
    if (source[i] === "{") {
      const before = source.slice(from, i);
      const kind = /\bnew\s+[\w.]+\s*(?:<[^;{}]*>|\[\s*\])\s*$/.test(before) ? "values"
        : /\bSystem\.runAs\s*\([^;{}]*\)\s*$/.test(before) ? "runAs" : "block";
      blocks.push(kind);
      if (kind !== "values") from = i + 1;
    } else if (source[i] === "}") {
      if (!blocks.length) return { found, end: i };
      if (blocks.pop() !== "values") from = i + 1;
    } else if (source[i] === ";") {
      const text = source.slice(from, i);
      const at = from + text.length - text.trimStart().length;
      found.push({ text: text.trim(), line: source.slice(0, at).split("\n").length, runAs: blocks.includes("runAs") });
      from = i + 1;
    }
  }
  throw new Error("unbalanced braces");
}

const methods = new Map();
let annotated = 0;
for (const name of names) {
  const cls = name.replace(/\.cls$/, "");
  const source = strip(await readFile(new URL(name, classes), "utf8"));
  annotated += source.match(/@(?:IsTest|TestSetup)\b(?:\([^)]*\))?\s+(?:(?:public|private|global|protected)\s+)?static\b/gi)?.length ?? 0;
  const header = /((?:@\w+(?:\([^)]*\))?\s+)*)(?:(?:public|private|global|protected)\s+)?static\s+([\w<>,.\[\] ]+?)\s+(\w+)\s*\(([^)]*)\)\s*\{/g;
  for (const match of source.matchAll(header)) {
    const { found, end } = statements(source, match.index + match[0].length);
    const key = `${cls}.${match[3]}`;
    const method = methods.get(key) ?? { file: name, cls, returns: [], test: false, code: [], statements: [] };
    method.test ||= /@(IsTest|TestSetup)\b/i.test(match[1]);
    method.returns.push(match[2]);
    method.code.push(match[4], source.slice(match.index + match[0].length, end));
    method.statements.push(...found);
    methods.set(key, method);
  }
}

const atlasType = (type) => /\bAtlas_\w+__c\b/.test(type ?? "");
const keywords = /^(insert|update|delete|undelete|upsert|return|new|as|else|throw)$/;
function typeOf(expression, method) {
  const value = expression.trim();
  const created = value.match(/^new\s+([\w.]+(?:<[^;]*>)?)/);
  if (created) return created[1];
  const call = value.match(/^(\w+)\s*\(/);
  if (call) return methods.get(`${method.cls}.${call[1]}`)?.returns.join(" ");
  const variable = value.match(/^\w+/)?.[0];
  if (!variable) return undefined;
  const declaration = new RegExp(`(?:^|[;{}(,])\\s*(?:final\\s+)?([A-Za-z_][\\w.]*(?:<[^;(){}]*>)?(?:\\[\\])?)\\s+${variable}\\s*[=;,)]`, "gm");
  return [...method.code.join(";").matchAll(declaration)].map((m) => m[1]).find((type) => !keywords.test(type));
}

// Atlas records read or written as the running user, outside System.runAs.
function userModeWork(method) {
  const problems = [];
  for (const { text, line, runAs } of method.statements) {
    if (runAs) continue;
    for (const query of text.match(/\[\s*SELECT\b[^\]]*\]/gi) ?? []) {
      if (/\bFROM\s+Atlas_/i.test(query) && !/\bWITH\s+SYSTEM_MODE\b/i.test(query)) problems.push({ line, text });
    }
    const dml = text.match(/^(?:insert|update|delete|undelete|upsert)\b(?!\s+as\s+system\b)(?:\s+as\s+user\b)?([\s\S]*)$/i);
    if (dml && atlasType(typeOf(dml[1], method))) problems.push({ line, text });
    const database = text.match(/\bDatabase\.(?:insert|update|delete|undelete|upsert)\s*\(([^,)]*)/);
    if (database && !/AccessLevel\.SYSTEM_MODE/.test(text) && atlasType(typeOf(database[1], method))) problems.push({ line, text });
  }
  return problems;
}

function helperCalls(method) {
  const calls = [];
  for (const { text, line, runAs } of method.statements) {
    if (runAs) continue;
    for (const call of text.matchAll(/(?<![\w.])(?<!\bnew\s+)(?:(Atlas_\w+)\.)?(\w+)\s*\(/g)) {
      const key = `${call[1] ?? method.cls}.${call[2]}`;
      if (methods.has(key) && !methods.get(key).test) calls.push({ line, text, key });
    }
  }
  return calls;
}

// A helper is unsafe if it does that work itself or calls another unsafe helper outside System.runAs.
const unsafe = new Set([...methods].filter(([, method]) => !method.test && userModeWork(method).length).map(([key]) => key));
for (let grew = true; grew;) {
  grew = false;
  for (const [key, method] of methods) {
    if (!method.test && !unsafe.has(key) && helperCalls(method).some((call) => unsafe.has(call.key))) {
      unsafe.add(key);
      grew = true;
    }
  }
}

test("Apex tests touch Atlas records as the deploying administrator only in system mode", () => {
  const tests = [...methods.values()].filter((method) => method.test);
  assert.equal(tests.length, annotated, "every Apex test method is found");
  const problems = [];
  for (const method of tests) {
    for (const { line, text } of userModeWork(method)) problems.push(`${method.file}:${line} ${text}`);
    for (const { line, text, key } of helperCalls(method)) {
      if (unsafe.has(key)) problems.push(`${method.file}:${line} ${text} (${key} runs as the user)`);
    }
  }
  assert.deepEqual(problems.sort(), []);
});
