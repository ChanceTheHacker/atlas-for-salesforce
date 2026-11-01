// Builds the Atlas deployment ZIP in artifacts/: the Salesforce project with the
// prebuilt Atlas_Files resource, the setup guide and checksums.
// Run: npm run package:salesforce
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { strToU8, zipSync } from "fflate";
import { buildSalesforce } from "./build-salesforce.mjs";

const root = new URL("../", import.meta.url);
const entries = {};
const add = async (path, as = path) => (entries[as] = new Uint8Array(await readFile(new URL(path, root))));

async function project(dir) {
  for (const entry of await readdir(new URL(dir, root), { withFileTypes: true })) {
    const path = dir + entry.name;
    if (entry.isDirectory()) await project(path + "/");
    else if (/\.(cls|trigger|xml|js|html|css|page|resource)$/.test(entry.name) || path === "salesforce/force-app/main/default/staticresources/Atlas_Extract.zip") await add(path);
    else throw new Error("Unexpected file in the Salesforce project: " + path);
  }
}

await buildSalesforce();
await project("salesforce/force-app/");
await add("salesforce/sfdx-project.json");
await add("docs/atlas-setup.md", "ATLAS-SETUP.md");
await add("THIRD-PARTY-NOTICES.txt");
entries["START-HERE.txt"] = strToU8(
  "Atlas for Salesforce\n\n" +
    "1. Read ATLAS-SETUP.md. It walks through installing into your org and the first use.\n" +
    "2. The Salesforce project is the salesforce/ folder. Run the sf commands from inside it.\n\n" +
    "Install into a sandbox first. Work includes Source, Task, UAT, Support Tickets and Files. Support Tickets investigates production incidents using test-org evidence; UAT creates a Word test plan with editable checkboxes and separate Source-mode repair prompts. Neither mode applies Salesforce repairs.\n\n" +
    "Jira uses CSV/manual work until you configure your Salesforce credentials in Team & Jira. Live Read and Write are separate switches; every live write requires exact review and approval. Set the Manager role and confirm that person's Jira identity in Team & Jira → People before preparing a live Bug escalation.\n",
);

const hash = (data) => createHash("sha256").update(data).digest("hex");
entries["SHA256SUMS"] = strToU8(
  Object.keys(entries)
    .sort()
    .map((path) => `${hash(entries[path])}  ${path}\n`)
    .join(""),
);
const zip = zipSync(entries, { level: 9, mtime: new Date(2000, 0, 1) });
const name = `Atlas-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-")}.zip`;
await mkdir(new URL("artifacts/", root), { recursive: true });
const output = new URL("artifacts/" + name, root);
await writeFile(output, zip, { flag: "wx" });
await writeFile(new URL(output.href + ".sha256"), `${hash(zip)}  ${name}\n`, { flag: "wx" });
console.log(`${output.pathname}\n${Object.keys(entries).length} files; ${zip.length} bytes; SHA-256 ${hash(zip)}`);
