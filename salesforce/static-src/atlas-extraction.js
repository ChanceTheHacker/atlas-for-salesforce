// LWS rejects new Worker(resourceUrl). A local static-resource frame owns the
// worker instead. Never parse on the UI thread or upload the selected document.
export const EXTRACTION_TIMEOUT_MS = 60000;
const CHANNEL = "atlas-extraction-v1";

export function startDocumentExtraction(file, { workerUrl, host, mode = "library", onProgress, timeoutMs = EXTRACTION_TIMEOUT_MS } = {}) {
  let frame, reader, timer, receive, settled = false, reading = false, resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  let id, origin;
  const unavailable = () => Error("Background document extraction is unavailable. Verify the Atlas_Extract static resource and iframe/worker CSP support. No file was uploaded or parsed on the UI thread.");
  const finish = (error, result) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    if (receive) window.removeEventListener("message", receive);
    if (reader) {
      reader.onload = reader.onerror = reader.onabort = reader.onprogress = null;
      if (reader.readyState === 1) reader.abort();
    }
    if (frame) {
      // Let the still-responsive frame terminate even a hung worker before it is
      // detached. Removing an iframe alone can leave Chromium workers running.
      const owner = frame;
      let cleanupTimer;
      const remove = () => { clearTimeout(cleanupTimer); window.removeEventListener("message", stopped); owner.remove(); };
      const stopped = (event) => {
        if (event.source === owner.contentWindow && event.origin === origin && event.data?.channel === CHANNEL && event.data.id === id && event.data.type === "stopped") remove();
      };
      window.addEventListener("message", stopped);
      cleanupTimer = setTimeout(remove, 1000);
      try { owner.contentWindow?.postMessage({channel: CHANNEL, id, type: "cancel"}, origin); }
      catch { remove(); }
    }
    reader = frame = null;
    if (error) reject(error); else resolve(result);
  };
  const notify = (text) => {
    if (settled) return;
    try { onProgress?.(text); } catch (error) { finish(error); }
  };
  const cancel = () => {
    const error = Error("Document extraction cancelled. No partial output was accepted.");
    error.name = "AbortError";
    finish(error);
  };
  try {
    if (!["library", "attachment"].includes(mode)) throw Error("Unknown document extraction mode.");
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > EXTRACTION_TIMEOUT_MS)
      throw Error("Document extraction timeout must be between 1 and 60,000 milliseconds.");
    const max = (mode === "library" ? 20 : 25) * 1024 * 1024;
    if (file.size > max) throw Error(`${file.name} is larger than ${max / 1024 / 1024} MB.`);
    if (typeof workerUrl !== "string" || !workerUrl || !host?.appendChild) throw unavailable();
    const url = new URL(workerUrl.replace(/\/$/, "") + "/host.html", window.location.href);
    origin = url.origin;
    if (!["http:", "https:"].includes(url.protocol) || origin !== window.location.origin) throw unavailable();
    id = Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
    url.hash = new URLSearchParams({id, origin}).toString();
    timer = setTimeout(() => finish(Error(`${file.name}: background extraction timed out after ${timeoutMs / 1000} seconds. Nothing from this selection was accepted; try a smaller supported export.`)), timeoutMs);
    notify("Starting background extractor…");
    if (settled) return { promise, cancel };
    frame = document.createElement("iframe");
    frame.title = "Atlas isolated document extractor";
    frame.hidden = true;
    frame.setAttribute("sandbox", "allow-scripts allow-same-origin");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.src = url.href;
    frame.onerror = () => finish(unavailable());
    receive = (event) => {
      if (settled || event.source !== frame.contentWindow || event.origin !== origin) return;
      const data = event.data;
      if (data?.channel !== CHANNEL || data.id !== id) return;
      try {
        if (data.type === "ready" && !reading) {
          reading = true;
          reader = new FileReader();
          reader.onerror = () => finish(Error(`${file.name}: the file could not be read.`));
          reader.onabort = cancel;
          reader.onprogress = (progress) => notify(progress.lengthComputable
            ? `Reading file: ${progress.total ? Math.floor(progress.loaded / progress.total * 100) : 100}%`
            : "Reading file…");
          reader.onload = () => {
            if (settled) return;
            notify("Extracting in background… (60-second limit per file)");
            if (settled) return;
            try { frame.contentWindow.postMessage({channel: CHANNEL, type: "extract", id, name: file.name, mode, bytes: reader.result}, origin, [reader.result]); }
            catch { finish(Error("The file could not be transferred to the background extractor. Nothing was accepted.")); }
          };
          notify("Reading file…");
          if (!settled) reader.readAsArrayBuffer(file);
        } else if (data.type === "progress" && typeof data.text === "string") notify(data.text);
        else if (data.type === "result") {
          if (mode === "library" ? typeof data.result !== "string" : !data.result || typeof data.result.text !== "string" || typeof data.result.kind !== "string" || !Array.isArray(data.result.warnings))
            throw Error("The background extractor returned an invalid result. Nothing was accepted.");
          finish(null, data.result);
        } else if (data.type === "error") finish(Error(typeof data.message === "string" ? data.message : "Background extraction failed."));
      } catch (error) { finish(error); }
    };
    window.addEventListener("message", receive);
    host.appendChild(frame);
  } catch (error) { finish(error); }
  return { promise, cancel };
}
