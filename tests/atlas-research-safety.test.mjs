// Offline policy checks use the actual Apex helper body, not a separately copied
// allowlist. This small syntax adapter does NOT replace running ResearchTest and
// AssignmentsTest in Salesforce; it cannot check Apex compilation or permissions.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const classes = new URL("../salesforce/force-app/main/default/classes/", import.meta.url);
const research = await readFile(new URL("Atlas_Research.cls", classes), "utf8");
const assignments = await readFile(new URL("Atlas_Assignments.cls", classes), "utf8");
const body = research.match(/static String readOnlyRestPath\(String path\) \{([\s\S]*?)\n    \}\n\n    static String rest/)[1];
class ApexSet extends Set {
  add(value) { const fresh = !this.has(value); super.add(value); return fresh; }
  addAll(values) { for (const value of values) this.add(value); }
  contains(value) { return this.has(value); }
}
const Pattern = {
  matches(pattern, value) { return new RegExp(`^(?:${pattern})$`).test(value); },
  compile(pattern) {
    return { matcher(value) {
      let match;
      return {
        matches() { match = new RegExp(`^(?:${pattern})$`).exec(value); return !!match; },
        group(i) { return match[i]; },
        find() { return new RegExp(pattern).test(value); },
      };
    } };
  },
};
const adapted = body
  .replace(/\b(?:String|Integer|Matcher) (\w+) = /g, "let $1 = ")
  .replace(/Set<String> (\w+) = new Set<String>\(\);/g, "const $1 = new ApexSet();")
  .replace(/new List<String>\{([^}]+)\}/g, "[$1]")
  .replace(/for \(String (\w+) : ([^\n]+)\) \{/g, "for (const $1 of $2) {")
  .replace(/String\.isBlank/g, "isBlank")
  .replace(/path\.contains\(/g, "path.includes(")
  .replace(/new Atlas_Api\.AtlasException/g, "new Error");
const allowPath = new Function("path", "Pattern", "ApexSet", "isBlank", "Atlas_Api", adapted);
const check = (path) => allowPath(path, Pattern, ApexSet, (v) => v == null || !v.trim(), { DATA: "/services/data/v67.0" });

const safe = [
  "limits", "/limits/", "/services/data/v66.0/limits",
  "/query/?q=SELECT+Id+FROM+Account", "/queryAll?q=SELECT%20Id%20FROM%20Account",
  "/query/01g000000000001AAA-2000", "/tooling/query/01g000000000001AAA-2000",
  "/tooling/query/?q=SELECT+Body+FROM+ApexClass", "/search/?q=FIND%20%7BAcme%7D",
  "/sobjects/", "/sobjects/Account/describe/", "/tooling/sobjects/", "/tooling/sobjects/ApexClass/describe",
  "/ui-api/record-ui/001000000000001?layoutTypes=Full&modes=View&optionalFields=Account.Name",
  "/ui-api/record-ui/001000000000001AAA,001000000000002AAA?formFactor=Small&childRelationships=Account.Contacts",
  "/query?q=SELECT+Id+FROM+Account+WHERE+Name%3D%27..%2F%252F%26_HttpMethod%3DDELETE%27",
];
const unsafe = [
  "/tooling/executeAnonymous/?anonymousBody=insert+new+Account%28Name%3D%27Unsafe%27%29%3B",
  "/services/data/v67.0/tooling/executeAnonymous/?anonymousBody=System.debug%281%29%3B",
  "/tooling/runTestsSynchronous/?classnames=Example", "/tooling/runTestsAsynchronous",
  "/composite", "/actions/custom/apex/Example", "/sobjects/Account/001000000000001",
  "/services/apexrest/Example", "https://example.com/limits", "//example.com/limits",
  "/limits/../tooling/executeAnonymous", "/limits/./", "/limits//",
  "/%74ooling/executeAnonymous", "/tooling%2FexecuteAnonymous", "/%2e%2e/tooling/executeAnonymous",
  "/limits/%252e%252e/tooling/executeAnonymous", "/services/data/v67.0%2ftooling/executeAnonymous",
  "/limits;anything", "/limits#fragment", "/limits\\tooling", "/limits\n",
  "/query?q=SELECT+Id+FROM+Account&_HttpMethod=DELETE",
  "/query?q=SELECT+Id+FROM+Account&%5fHttpMethod=POST",
  "/query?q=SELECT+Id+FROM+Account;_HttpMethod=POST",
  "/query?q=one&q=two", "/limits?anything=1", "/query?",
  "/ui-api/record-ui/001000000000001?_HttpMethod=PATCH",
  "/ui-api/record-ui/001000000000001%2f..%2f..%2f..%2ftooling%2fexecuteAnonymous",
];

test("Apex REST policy preserves documented reads and encoded query data", () => {
  for (const path of safe) {
    const expected = path.startsWith("/services/data/") ? path : "/services/data/v67.0" + (path.startsWith("/") ? "" : "/") + path;
    assert.equal(check(path), expected, path);
  }
});

test("Apex REST policy rejects mutating and ambiguous URLs, including method overrides", () => {
  for (const path of unsafe) assert.throws(() => check(path), /approved read-only Salesforce paths/, path);
});

test("percent-encoding route characters never bypasses the canonical allowlist", () => {
  for (const path of ["/tooling/executeAnonymous", "/tooling/runTestsSynchronous", "/limits/../tooling/executeAnonymous"]) {
    for (let i = 0; i < path.length; i++) {
      const encoded = "%" + path.charCodeAt(i).toString(16).padStart(2, "0");
      for (const replacement of [encoded, encoded.toUpperCase(), "%25" + encoded.slice(1)]) {
        assert.throws(() => check(path.slice(0, i) + replacement + path.slice(i + 1)), /approved read-only Salesforce paths/);
      }
    }
  }
});

test("REST validates before the callout and Case assignments recheck stored mode", () => {
  const rest = research.slice(research.indexOf("static String rest(String path)"), research.indexOf("// ---------------------------------------------------------------- describe"));
  assert.match(rest, /path = readOnlyRestPath\(path\);\s*String body = Atlas_Api.get\(path, null\);/);
  const prepare = assignments.slice(assignments.indexOf("public static String prepare("), assignments.indexOf("public static String decide("));
  assert.match(prepare, /accessibleConversation\(conversationId\);\s*Atlas_Data.assertSourceChangesAllowed\(conversationId\);\s*List<Object> requested/);
  const decide = assignments.slice(assignments.indexOf("public static String decide("));
  const guard = decide.indexOf("if (approve == true) Atlas_Data.assertSourceChangesAllowed(conversationId);");
  assert.ok(guard >= 0 && guard < decide.indexOf("String receipt"), "Approval guard must precede both receipt replay and record updates.");
});
