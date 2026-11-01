import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createServer } from "node:http";
import { chromium } from "playwright";
import { zipSync, strToU8, unzipSync } from "fflate";
import { burn } from "@kenjiuno/msgreader/lib/Burner.js";
import { buildSalesforce } from "../scripts/build-salesforce.mjs";
import { extractDocument } from "../src/files-extract.js";

// Pure DOM/text automation: headless, default software GPU, no shared profile, credentials or
// external network. Set CHROMIUM_PATH to use a system browser instead of Playwright's own.
const zip = (entries) => zipSync(Object.fromEntries(Object.entries(entries).map(([name, text]) => [name, strToU8(text)])));
const word = (body) => zip({ "word/document.xml": `<w:document xmlns:w="word"><w:body>${body}</w:body></w:document>` });
const stream = (tag, text) => {
  const bytes = Uint8Array.from(Buffer.from(text + "\0", "utf16le"));
  return {name: "__substg1.0_" + tag, type: 2, length: bytes.length, binaryProvider: () => bytes};
};
const fixtures = [
  ["message.msg", burn([
    {name: "Root Entry", type: 5, length: 0, children: [1, 2, 3, 4]},
    stream("0037001F", "Subject café"), stream("0C1A001F", "Sender"), stream("1000001F", "Message body"),
    {name: "__attach_version1.0_#00000000", type: 1, length: 0, children: [5]}, stream("3707001F", "Plan.docx"),
  ])],
  ["document.docx", word("<w:p><w:r><w:t>Included</w:t></w:r><w:del><w:r><w:t>Deleted</w:t></w:r></w:del></w:p>")],
  ["sheets.xlsx", zip({
    "xl/workbook.xml": '<workbook xmlns:r="rel"><sheets><sheet name="Hidden" state="hidden" r:id="sheet"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": '<Relationships><Relationship Id="sheet" Target="worksheets/sheet.xml"/></Relationships>',
    "xl/worksheets/sheet.xml": '<worksheet><sheetData><row><c r="A1"><f>1+2</f><v>3</v></c></row></sheetData></worksheet>',
  })],
  ["slides.pptx", zip({
    "ppt/presentation.xml": '<presentation xmlns:r="rel"><sldId r:id="slide"/></presentation>',
    "ppt/_rels/presentation.xml.rels": '<Relationships><Relationship Id="slide" Target="slides/slide.xml"/></Relationships>',
    "ppt/slides/slide.xml": '<slide><p><t>Slide text</t></p></slide>',
    "ppt/slides/_rels/slide.xml.rels": '<Relationships><Relationship Id="note" Type="x/notesSlide" Target="../notesSlides/note.xml"/></Relationships>',
    "ppt/notesSlides/note.xml": '<note><p><t>Speaker note</t></p></note>',
  })],
  ["email.eml", strToU8('Subject: Test\r\nFrom: a@example.invalid\r\nContent-Type: text/html\r\n\r\n<p>Email body</p><script>evil()</script><img src="https://example.invalid/tracker">')],
  ["broken.msg", strToU8("not an MSG compound file")],
  ["unsupported.pdf", strToU8("%PDF")],
  ["broken.docx", word("<!DOCTYPE x [<!ENTITY a 'bad'>]><w:p>&a;</w:p>")],
  ["binary.txt", new Uint8Array([0, 1, 2])],
  ["invalid-utf8.txt", new Uint8Array([255])],
  ..."txt md csv tsv json jsonl xml yaml yml log html htm js ts css cls sql".split(" ").map((ext) => [`source.${ext}`, strToU8("<p>plain UTF-8 é</p><script>evil()</script>")]),
];

test("built static-resource worker extracts locally, remains cancellable and fails closed", { timeout: 120000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "atlas-extraction-browser-"));
  let browser, server;
  try {
    const size = await buildSalesforce({ outputDir: pathToFileURL(dir + "/") });
    assert.ok(size < 5 * 1024 * 1024);
    const main = await readFile(join(dir, "Atlas_Files.js"));
    const archive = unzipSync(await readFile(join(dir, "Atlas_Extract.zip")));
    const worker = archive["worker.js"];
    assert.ok(worker.length < 5 * 1024 * 1024);
    assert.match(await readFile(join(dir, "Atlas_Extract.resource-meta.xml"), "utf8"), /application\/zip/);
    const requests = [];
    let blockWorker = false;
    server = createServer((req, res) => {
      requests.push(req.url);
      res.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; worker-src 'self'; frame-src 'self'; connect-src 'none'");
      res.setHeader("Content-Type", req.url.endsWith(".js") ? "application/javascript" : "text/html");
      if (req.url === "/Atlas_Files.js") res.end(main);
      else if (/^\/(extract|hung|silent|broken)\//.test(req.url)) {
        const [, kind, file] = req.url.split("/");
        if (file === "worker.js" && kind === "hung") res.end("self.onmessage = () => { while (true) {} }; self.postMessage({type:'ready'});");
        else if (file === "worker.js" && kind === "silent") res.end("// No ready message.");
        else if (file === "worker.js" && kind === "broken") res.end("throw Error('broken worker');");
        else res.end(file === "host.html" && blockWorker ? Buffer.from(archive[file]).toString().replace("worker-src 'self'", "worker-src 'none'") : archive[file]);
      }
      else if (req.url === "/") res.end('<button id="ordinary">Ordinary UI</button><input id="typing"><div id="host"></div><script src="/Atlas_Files.js"></script>');
      else { res.statusCode = 404; res.end(); }
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    try {
      browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined, headless: true });
    } catch (error) {
      t.skip(`No browser to run the extraction worker in: ${error.message.split("\n")[0]}`);
      return;
    }
    const page = await browser.newPage({ serviceWorkers: "block" });
    await page.goto(origin);
    await page.evaluate(() => {
      document.querySelector("#ordinary").onclick = () => { window.clickedDuringExtraction = !window.extractionFinished; };
    });
    const cdp = await browser.newBrowserCDPSession();
    const noWorkers = async () => {
      for (let i=0; i<300; i++) {
        const active = (await cdp.send("Target.getTargets")).targetInfos.filter((t) => t.type === "worker");
        if (!active.length) return;
        await page.waitForTimeout(20);
      }
      assert.fail("Dedicated extraction worker target still active after cleanup");
    };

    await t.test("all supported formats, warnings and unavailable states match the legacy parser", async () => {
      for (const [name, bytes] of fixtures) {
        const expected = await extractDocument(name, bytes);
        const actual = await page.evaluate(async ({ name, bytes }) => {
          const progress = [];
          const job = AtlasFiles.startDocumentExtraction(new File([new Uint8Array(bytes)], name), {
            workerUrl: "/extract", host: document.querySelector("#host"), onProgress: (text) => progress.push(text),
          });
          return { doc: JSON.parse(await job.promise), progress };
        }, { name, bytes: [...bytes] });
        // Native TextDecoder wording differs between Chromium and Node, not parser behavior.
        if (name === "invalid-utf8.txt") {
          assert.match(actual.doc.notice, /Cannot extract: .*encoded data was not valid/);
          expected.notice = actual.doc.notice;
        }
        assert.deepEqual(actual.doc, { ...expected, warnings: expected.notice ? [expected.notice] : [] }, name);
        assert.ok(actual.progress.some((text) => /Extracting in background/.test(text)), name);
      }
    });

    await t.test("attachment output retains the warning and rejects unsupported PDF", async () => {
      const result = await page.evaluate(async () => {
        const run = (name, body) => AtlasFiles.startDocumentExtraction(new File([body], name), { workerUrl: "/extract", host: document.querySelector("#host"), mode: "attachment" }).promise;
        return { doc: await run("small.txt", "hello"), error: await run("file.pdf", "%PDF").catch((e) => e.message) };
      });
      assert.equal(result.doc.text, "[Text]\nhello");
      assert.match(result.doc.warnings[0], /UTF-8/);
      assert.match(result.error, /Unsupported.*PDF/);
    });

    await t.test("input, extracted text and expanded XML limits remain explicit", async () => {
      const results = await page.evaluate(async () => {
        const run = (file, mode = "library") => AtlasFiles.startDocumentExtraction(file, {workerUrl: "/extract", host: document.querySelector("#host"), mode}).promise;
        const overInput = new File([new Uint8Array(20 * 1024 * 1024 + 1)], "large.txt");
        const overText = new File(["x".repeat(5 * 1024 * 1024 + 1)], "text.txt");
        return {
          library: await run(overInput).catch((e) => e.message),
          attachment: await run(overInput, "attachment").catch((e) => e.message),
          text: JSON.parse(await run(overText)),
        };
      });
      assert.match(results.library, /larger than 20 MB/);
      assert.match(results.attachment, /Over 20 MB; inventory only/);
      assert.equal(results.text.state, "unavailable");
      assert.match(results.text.notice, /exceeds 5 MB/);
      for (const bytes of [
        zip({"word/document.xml": " ".repeat(12 * 1024 * 1024 + 1)}),
        zip(Object.fromEntries(Array.from({length: 4}, (_, i) => [`part${i}.xml`, " ".repeat(11 * 1024 * 1024)]))),
        zip({"../word/document.xml": "<document/>"}),
        zip(Object.fromEntries(Array.from({length: 10001}, (_, i) => [`part${i}.txt`, ""]))),
      ]) {
        const result = await page.evaluate(async (bytes) => JSON.parse(await AtlasFiles.startDocumentExtraction(new File([new Uint8Array(bytes)], "large.docx"), {workerUrl: "/extract", host: document.querySelector("#host")}).promise), [...bytes]);
        assert.equal(result.state, "unavailable");
        assert.match(result.notice, /safe extraction limit|Unsafe archive path|too many entries/);
        assert.deepEqual(result.sections, []);
      }
    });

    const heavy = [...word("<w:p><w:r><w:t>Text</w:t></w:r></w:p>".repeat(200000))];
    await t.test("real XML parse leaves clicks, typing and timers responsive", async () => {
      await page.evaluate((bytes) => {
        window.extractionFinished = false; window.ticks = 0; window.stage = "";
        const timer = setInterval(() => ticks++, 10);
        window.job = AtlasFiles.startDocumentExtraction(new File([new Uint8Array(bytes)], "heavy.docx"), {
          workerUrl: "/extract", host: document.querySelector("#host"), onProgress: (text) => { stage = text; },
        });
        window.outcome = job.promise.then((raw) => ({ state: JSON.parse(raw).state })).finally(() => { extractionFinished = true; clearInterval(timer); });
      }, heavy);
      await page.waitForFunction(() => stage.startsWith("Extracting in background"));
      await page.click("#ordinary");
      await page.fill("#typing", "UI still works");
      const result = await page.evaluate(async () => ({ result: await outcome, ticks, clickedDuringExtraction }));
      assert.equal(result.result.state, "readable");
      assert.equal(result.clickedDuringExtraction, true);
      assert.ok(result.ticks > 3, `Expected live UI timer ticks, got ${result.ticks}`);
    });

    await t.test("cancel terminates an actual heavy parse with no partial result", async () => {
      await page.evaluate((bytes) => {
        window.stage = "";
        window.job = AtlasFiles.startDocumentExtraction(new File([new Uint8Array(bytes)], "heavy.docx"), {
          workerUrl: "/extract", host: document.querySelector("#host"), onProgress: (text) => { stage = text; },
        });
        window.outcome = job.promise.then(() => "unexpected result", (e) => e.name);
      }, heavy);
      await page.waitForFunction(() => stage.startsWith("Extracting in background"));
      assert.equal(await page.evaluate(async () => { job.cancel(); job.cancel(); return outcome; }), "AbortError");
      await noWorkers();
    });

    await t.test("cancel while reading aborts the real FileReader and terminates its worker", async () => {
      const result = await page.evaluate(async () => {
        const nativeAbort = FileReader.prototype.abort;
        let aborts = 0;
        FileReader.prototype.abort = function () { aborts++; return nativeAbort.call(this); };
        try {
          const job = AtlasFiles.startDocumentExtraction(new File([new Uint8Array(20 * 1024 * 1024)], "reading.txt"), {
            workerUrl: "/extract", host: document.querySelector("#host"),
            onProgress: (text) => { if (text === "Reading file…") queueMicrotask(() => job.cancel()); },
          });
          return {error: await job.promise.catch((e) => e.name), aborts};
        } finally { FileReader.prototype.abort = nativeAbort; }
      });
      assert.equal(result.error, "AbortError");
      assert.equal(result.aborts, 1);
      await noWorkers();
    });

    await t.test("startup, parsing timeout, script crash and CSP refusal clean up without fallback", async () => {
      for (const [url, pattern] of [["/silent", /timed out/], ["/hung", /timed out/], ["/broken", /could not run/]]) {
        const error = await page.evaluate(async (workerUrl) => {
          const job = AtlasFiles.startDocumentExtraction(new File(["hi"], "a.txt"), { workerUrl, host: document.querySelector("#host"), timeoutMs: 400 });
          return job.promise.then(() => "unexpected", (e) => e.message);
        }, url);
        assert.match(error, pattern);
        await noWorkers();
      }
      blockWorker = true;
      await page.evaluate(() => {
        const meta = document.createElement("meta");
        meta.httpEquiv = "Content-Security-Policy"; meta.content = "worker-src 'none'"; document.head.appendChild(meta);
      });
      const error = await page.evaluate(() => AtlasFiles.startDocumentExtraction(new File(["hi"], "a.txt"), {
        workerUrl: "/extract", host: document.querySelector("#host"), timeoutMs: 1000,
      }).promise.catch((e) => e.message));
      assert.match(error, /could not run/);
      await noWorkers();
    });

    await noWorkers();
    assert.ok(requests.every((url) => /^\/(extract|hung|silent|broken)\/(host.html|host.js|worker.js)$/.test(url) || ["/", "/Atlas_Files.js", "/favicon.ico"].includes(url)));
  } finally {
    await browser?.close();
    if (server) await new Promise((resolve) => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
});
