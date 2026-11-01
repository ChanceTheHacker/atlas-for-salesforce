// Builds the Atlas_Files static resource from src/files-extract.js and
// src/files-output.js. Run before deploying: npm run build:salesforce
import { mkdir, writeFile } from "node:fs/promises";
import { build } from "esbuild";
import { zipSync, strToU8 } from "fflate";

const root = new URL("../", import.meta.url);
const dir = new URL("salesforce/force-app/main/default/staticresources/", root);

export async function buildSalesforce({ outputDir = dir } = {}) {
  const result = await build({
    entryPoints: [new URL("salesforce/static-src/atlas-files.js", root).pathname],
    bundle: true,
    write: false,
    format: "iife",
    globalName: "AtlasFiles",
    target: "es2022",
    platform: "browser",
    minify: true,
    legalComments: "eof",
    logLevel: "warning",
  });
  const code = result.outputFiles[0].text;
  if (code.length > 5 * 1024 * 1024) throw new Error(`Atlas_Files is ${code.length} bytes; static resources are limited to 5 MB.`);
  const worker = await build({
    entryPoints: [new URL("salesforce/static-src/atlas-extract-worker.js", root).pathname],
    bundle: true, write: false, format: "iife", target: "es2022", platform: "browser",
    minify: true, legalComments: "eof", logLevel: "warning",
  });
  const workerCode = worker.outputFiles[0].contents;
  if (workerCode.length > 5 * 1024 * 1024) throw new Error(`Atlas_Extract is ${workerCode.length} bytes; static resources are limited to 5 MB.`);
  const host = await build({
    entryPoints: [new URL("salesforce/static-src/atlas-extract-host.js", root).pathname],
    bundle: true, write: false, format: "iife", target: "es2022", platform: "browser",
    minify: true, legalComments: "eof", logLevel: "warning",
  });
  const html = '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\'; worker-src \'self\'; connect-src \'none\'; base-uri \'none\'; form-action \'none\'"><title>Atlas isolated document extractor</title></head><body><script src="host.js"></script></body></html>';
  const archive = zipSync({"host.html": strToU8(html), "host.js": host.outputFiles[0].contents, "worker.js": workerCode}, {level: 9, mtime: new Date(2000, 0, 1)});
  if (archive.length > 5 * 1024 * 1024) throw new Error(`Atlas_Extract is ${archive.length} bytes; static resources are limited to 5 MB.`);
  await mkdir(outputDir, { recursive: true });
  await writeFile(new URL("Atlas_Extract.zip", outputDir), archive);
  await writeFile(new URL("Atlas_Extract.resource-meta.xml", outputDir), `<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Private</cacheControl>
    <contentType>application/zip</contentType>
    <description>Atlas: local isolated document extraction frame and dedicated worker. No external network or UI-thread parsing.</description>
</StaticResource>
`);
  await writeFile(new URL("Atlas_Files.js", outputDir), code);
  await writeFile(
    new URL("Atlas_Files.resource-meta.xml", outputDir),
    `<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Private</cacheControl>
    <contentType>application/javascript</contentType>
    <description>Atlas: reads attached Office documents and creates Word, Excel, PowerPoint and email files.</description>
</StaticResource>
`,
  );
  return code.length;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const size = await buildSalesforce();
  console.log(`Atlas_Files.js: ${(size / 1024).toFixed(0)} KB`);
}
