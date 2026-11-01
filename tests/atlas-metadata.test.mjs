// Static checks on the Atlas Salesforce metadata, so naming, permission and
// wiring mistakes show up before a deploy instead of in the org.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { DOMParser } from "@xmldom/xmldom";

const root = new URL("../salesforce/force-app/main/default/", import.meta.url);
const read = (path) => readFile(new URL(path, root), "utf8");
const list = async (path) => (await readdir(new URL(path, root))).sort();

function xml(text, path) {
  const errors = [];
  const doc = new DOMParser({ onError: (level, message) => level !== "warning" && errors.push(message) }).parseFromString(text, "text/xml");
  assert.deepEqual(errors, [], path);
  return doc;
}
const values = (doc, tag) => Array.from(doc.getElementsByTagName(tag), (n) => n.textContent.trim());

test("every metadata file is valid XML", async () => {
  for (const folder of await list("")) {
    const walk = async (path) => {
      for (const row of await readdir(new URL(path, root), { withFileTypes: true })) {
        const child = path + row.name;
        if (row.isDirectory()) await walk(child + "/");
        else if (row.name.endsWith(".xml")) xml(await read(child), child);
      }
    };
    await walk(folder + "/");
  }
});

test("everything Atlas creates is named Atlas", async () => {
  for (const folder of await list("")) {
    for (const name of await list(folder + "/")) {
      if (folder === "lwc") assert.match(name, /^atlas/, `lwc/${name}`);
      else assert.match(name, /^Atlas(_|\.)/, `${folder}/${name}`);
    }
  }
  for (const object of await list("objects/")) {
    const doc = xml(await read(`objects/${object}/${object}.object-meta.xml`), object);
    assert.match(values(doc, "label")[0], /^Atlas /, object);
    assert.match(values(doc, "pluralLabel")[0], /^Atlas /, object);
  }
  for (const path of ["applications/Atlas.app-meta.xml", "tabs/Atlas.tab-meta.xml", "permissionsets/Atlas_User.permissionset-meta.xml", "pages/Atlas_Session.page-meta.xml"])
    assert.match(values(xml(await read(path), path), "label")[0], /^Atlas( |$)/, path);
});

test("UAT is a restricted conversation mode", async () => {
  const path = "objects/Atlas_Conversation__c/fields/Mode__c.field-meta.xml";
  const doc = xml(await read(path), path);
  assert.deepEqual(values(doc, "restricted"), ["true"]);
  const options = Array.from(doc.getElementsByTagName("value"), (option) => ({
    apiName: option.getElementsByTagName("fullName")[0]?.textContent.trim(),
    label: option.getElementsByTagName("label")[0]?.textContent.trim(),
  }));
  assert.deepEqual(options.filter((option) => option.apiName === "uat"), [{ apiName: "uat", label: "UAT" }]);
});

test("the Atlas User permission set covers every object, field and class", async () => {
  const doc = xml(await read("permissionsets/Atlas_User.permissionset-meta.xml"));
  const fields = new Set(values(doc, "field"));
  const objects = new Set(values(doc, "object"));
  for (const object of await list("objects/")) {
    assert.ok(objects.has(object), `object access for ${object}`);
    for (const file of await list(`objects/${object}/fields/`)) {
      const field = xml(await read(`objects/${object}/fields/${file}`), file);
      // Required and master-detail fields always have access and cannot be listed.
      if (values(field, "required")[0] === "true" || values(field, "type")[0] === "MasterDetail") continue;
      assert.ok(fields.has(`${object}.${file.replace(".field-meta.xml", "")}`), `field access for ${object}.${file}`);
    }
  }
  const classes = new Set(values(doc, "apexClass"));
  for (const file of await list("classes/"))
    if (file.endsWith(".cls") && !/Test\.cls$|Mock\.cls$/.test(file)) assert.ok(classes.has(file.slice(0, -4)), `class access for ${file}`);
  assert.ok(values(doc, "apexPage").includes("Atlas_Session"));
  assert.ok(values(doc, "tab").includes("Atlas"));
  assert.ok(values(doc, "application").includes("Atlas"));
});

test("every Apex method and component the LWCs use exists", async () => {
  const apex = new Map();
  for (const file of await list("classes/")) {
    if (!file.endsWith(".cls")) continue;
    const source = await read("classes/" + file);
    const methods = new Set();
    for (const m of source.matchAll(/@AuraEnabled[^\n]*\n\s*public static [\w<>, .]+?\s+(\w+)\s*\(/g)) methods.add(m[1]);
    apex.set(file.slice(0, -4), methods);
  }
  const bundles = new Set(await list("lwc/"));
  for (const bundle of bundles) {
    for (const file of await list(`lwc/${bundle}/`)) {
      const text = await read(`lwc/${bundle}/${file}`);
      if (file.endsWith(".js"))
        for (const m of text.matchAll(/from\s+["']@salesforce\/apex\/(\w+)\.(\w+)["']/g))
          assert.ok(apex.get(m[1])?.has(m[2]), `${bundle}/${file} imports ${m[1]}.${m[2]}, which is not an @AuraEnabled method`);
      if (file.endsWith(".js"))
        for (const m of text.matchAll(/from\s+["']c\/(\w+)["']/g)) assert.ok(bundles.has(m[1]), `${bundle}/${file} imports c/${m[1]}`);
      if (file.endsWith(".html"))
        for (const m of text.matchAll(/<c-([\w-]+)/g)) {
          const name = m[1].replace(/-(\w)/g, (_, c) => c.toUpperCase());
          assert.ok(bundles.has(name), `${bundle}/${file} uses <c-${m[1]}>`);
        }
    }
  }
});
