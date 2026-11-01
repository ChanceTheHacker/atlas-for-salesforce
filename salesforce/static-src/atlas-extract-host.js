// Runs as a static-resource document, outside the Lightning Web Security sandbox.
// Only the worker parses bytes; this frame has no network or DOM rendering duties.
const channel = "atlas-extraction-v1";
const params = new URLSearchParams(location.hash.slice(1));
const id = params.get("id"), origin = params.get("origin");
let worker, accepted = false, stopped = false;
const stop = () => { stopped = true; worker?.terminate(); worker = null; };
const send = (message) => parent.postMessage({ channel, id, ...message }, origin);
if (parent !== window && /^[a-f0-9]{32}$/.test(id || "") && origin === location.origin) {
  addEventListener("pagehide", stop);
  addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== parent || event.origin !== origin || data?.channel !== channel || data.id !== id) return;
    if (data.type === "cancel") { stop(); setTimeout(() => send({type: "stopped"}), 0); return; }
    if (stopped) return;
    if (data.type !== "extract" || accepted || !["library", "attachment"].includes(data.mode) || typeof data.name !== "string" || !(data.bytes instanceof ArrayBuffer)) return;
    accepted = true;
    worker.postMessage({ id, name: data.name, mode: data.mode, bytes: data.bytes }, [data.bytes]);
  });
  try {
    worker = new Worker("worker.js", { name: "Atlas document extraction" });
    worker.onerror = (event) => { event.preventDefault(); send({type: "error", message: "The isolated document worker could not run. Nothing was accepted."}); stop(); };
    worker.onmessageerror = () => { send({type: "error", message: "The isolated document worker returned an unreadable message."}); stop(); };
    worker.onmessage = ({ data }) => {
      if (stopped) return;
      if (data?.type === "ready" && !accepted) send({type: "ready"});
      else if (data?.id === id && ["progress", "result", "error"].includes(data.type)) {
        send(data);
        if (data.type !== "progress") stop();
      }
    };
  } catch { send({type: "error", message: "The isolated document worker is unavailable. No UI-thread fallback was used."}); stop(); }
}
