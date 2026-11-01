import test from "node:test";
import assert from "node:assert/strict";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {pathToFileURL} from "node:url";
import {unzipSync, strFromU8} from "fflate";
import {buildSalesforce} from "../scripts/build-salesforce.mjs";

// Local artifacts only: no deployment or release publication.
test("extractor ZIP rebuilds byte-identically with fixed nested timestamps", async () => {
  const dir = await mkdtemp(join(tmpdir(), "atlas-build-"));
  const outputDir = pathToFileURL(dir + "/");
  try {
    await buildSalesforce({outputDir});
    const first = await readFile(join(dir, "Atlas_Extract.zip"));
    await buildSalesforce({outputDir});
    assert.deepEqual(await readFile(join(dir, "Atlas_Extract.zip")), first);
    const files = unzipSync(first);
    assert.deepEqual(Object.keys(files).sort(), ["host.html", "host.js", "worker.js"]);
    assert.match(strFromU8(files["host.html"]), /worker-src 'self'/);
    // Every local ZIP header uses midnight 2000-01-01 (DOS date 0x2821).
    for (let at = 0; at < first.length - 30; at++) if (first.readUInt32LE(at) === 0x04034b50) {
      assert.equal(first.readUInt16LE(at + 10), 0);
      assert.equal(first.readUInt16LE(at + 12), 0x2821);
    }
    const meta = await readFile(join(dir, "Atlas_Extract.resource-meta.xml"), "utf8");
    assert.match(meta, /<contentType>application\/zip<\/contentType>/);
    const ignore = await readFile(new URL("../.gitignore", import.meta.url), "utf8");
    assert.ok(ignore.split("\n").includes("salesforce/force-app/main/default/staticresources/Atlas_Extract.zip"));
    assert.ok(!ignore.split("\n").includes("salesforce/force-app/main/default/staticresources/Atlas_Extract.resource-meta.xml"));
  } finally { await rm(dir, {recursive: true}); }
});
