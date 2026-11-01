import { readFile, readdir, writeFile } from "node:fs/promises";

// Include the production tree, not just esbuild inputs: browser distributions
// such as ExcelJS also contain vendored code inside their prebuilt bundles.
const root = new URL("../", import.meta.url);
const lock = JSON.parse(
  await readFile(new URL("package-lock.json", root), "utf8"),
);
const sections = [
  "Atlas embeds its runtime libraries locally; no CDN/runtime downloads.\nThe following notices cover the locked production dependency tree, including\npackages that may be omitted by browser bundling/tree shaking. These licenses\napply to the named libraries, not necessarily to the rest of Atlas.",
];
const missing = [];
for (const [path, pkg] of Object.entries(lock.packages).sort(([a], [b]) =>
  a.localeCompare(b),
)) {
  if (!path || pkg.dev || pkg.devOptional) continue;
  const dir = new URL(path + "/", root),
    meta = JSON.parse(await readFile(new URL("package.json", dir), "utf8"));
  const files = (await readdir(dir)).filter((n) =>
    /^(licen[sc]e|copying|notice)(\.|$)/i.test(n),
  );
  const texts = [];
  for (const name of files.sort()) {
    try {
      texts.push(name + "\n" + (await readFile(new URL(name, dir), "utf8")));
    } catch (e) {
      if (e.code !== "EISDIR") throw e;
    }
  }
  if (!texts.length) {
    for (const name of (await readdir(dir)).filter((n) =>
      /^readme\./i.test(n),
    )) {
      const readme = await readFile(new URL(name, dir), "utf8");
      const start = readme.search(/^(?:#+\s*)?licen[sc]e\s*$/im);
      if (
        start >= 0 &&
        /Permission is hereby granted/.test(readme.slice(start))
      )
        texts.push(readme.slice(start));
    }
  }
  if (!texts.length && meta.name === "saxes")
    texts.push(
      await readFile(
        new URL("third-party/saxes-5.0.1-LICENSE.txt", root),
        "utf8",
      ),
    );
  // Node-only unzipper helpers and an empty https placeholder are not present
  // in the browser distributions; they have no code shipped in the HTML.
  if (
    !texts.length &&
    ["binary", "buffers", "chainsaw", "https"].includes(meta.name)
  )
    continue;
  if (!texts.length) missing.push(meta.name);
  sections.push(
    `===== ${meta.name}@${meta.version} — ${meta.license || pkg.license || "See package notice"} =====\n${texts.join("\n\n") || "License text not supplied in package."}`,
  );
}
if (missing.length) throw Error("Missing license files: " + missing.join(", "));
const excel = await readFile(
  new URL("node_modules/exceljs/dist/exceljs.js", root),
  "utf8",
);
const embedded = [
  ...excel.matchAll(/\/\*[\s\S]*?\*\//g),
  ...excel.matchAll(/(?:^[ \t]*\/\/[^\n]*\n)+/gm),
]
  .map((m) => m[0])
  .filter((s) => /copyright|@license|@preserve/i.test(s));
sections.push(
  "===== Additional notices embedded in the ExcelJS browser distribution =====\n" +
    [...new Set(embedded)].join("\n\n"),
);
await writeFile(
  new URL("THIRD-PARTY-NOTICES.txt", root),
  sections.join("\n\n") + "\n",
);
console.log(
  "Wrote notices for " + (sections.length - 1) + " production packages.",
);
