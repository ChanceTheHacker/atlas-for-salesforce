// One ordered outbox per org/user/conversation. Remounting a panel shares its
// in-flight write; a hard reload replays stable server-checked message identities.
const queues = new Map();
export function historyQueue(key, write) {
  if (key && queues.has(key)) return queues.get(key);
  const listeners = new Set();
  // stored: the browser copy matches pending, so a reload can replay it.
  // unreadable: an earlier copy could not be read; it is left untouched.
  let pending = [], running, failure = "", stored = true, unreadable = false;
  try {
    const saved = key ? JSON.parse(sessionStorage.getItem(key) || "[]") : [];
    if (!Array.isArray(saved) || saved.some((m) => !m || typeof m.nonce !== "string" || typeof m.body !== "string")) throw Error("Invalid saved history");
    pending = saved;
  } catch { unreadable = true; }
  const recoverable = () => !pending.length || (stored && !!key && !unreadable);
  const problem = () => {
    const where = recoverable() ? "" : ` ${pending.length} message(s) are held only in this tab because browser recovery is unavailable. Keep it open, or download them.`;
    if (failure) return `History NOT saved: ${failure}${where}`;
    if (where) return `Waiting for Salesforce.${where}`;
    return unreadable ? "Browser history recovery is unavailable. New messages wait for Salesforce before the input clears." : "";
  };
  const notify = (rows = []) => { for (const listener of listeners) listener({pending: pending.length, recoverable: recoverable(), problem: problem(), rows}); };
  const store = () => {
    if (!key || unreadable) return (stored = false);
    try {
      if (pending.length) sessionStorage.setItem(key, JSON.stringify(pending));
      else sessionStorage.removeItem(key);
      return (stored = true);
    } catch { return (stored = false); }
  };
  const queue = {
    get pending() { return pending; },
    /** False while any unsaved message exists only in this tab's memory. */
    get recoverable() { return recoverable(); },
    subscribe(listener) { listeners.add(listener); notify(); return () => listeners.delete(listener); },
    enqueue(message) {
      if (typeof message.body !== "string" || message.body.length > 1500000)
        throw Error("A history message exceeds Salesforce's 1,500,000-character limit. Keep or download the reply and request smaller batches; it was not added to the save queue.");
      if (pending.length >= 50 || pending.reduce((n, m) => n + m.body.length, message.body.length) > 2000000)
        throw Error("History saving is behind. Retry Save history or download the unsaved messages before processing more replies.");
      const nonce = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
      pending = [...pending, {...message, nonce}];
      store();
      notify();
      const work = queue.flush();
      // Only a message a reload can replay may be left to finish in the background.
      if (recoverable()) { work.catch(() => {}); return Promise.resolve(); }
      return work;
    },
    flush() {
      // A new message can arrive after the drain loop ends but before its
      // promise settles. Its caller must wait for a fresh drain in that case.
      if (running) return running.then(() => pending.length ? queue.flush() : undefined);
      running = Promise.resolve().then(async () => {
        while (pending.length) {
          // Two ordinary messages share a transaction. Large bodies go alone to
          // leave room for Salesforce's synchronous heap and File storage.
          const batch = pending.slice(0, pending[0].body.length + (pending[1]?.body.length || 0) <= 750000 ? 2 : 1);
          const rows = await write(batch);
          if (!Array.isArray(rows) || rows.length !== batch.length || rows.some((r, i) => r.nonce !== batch[i].nonce || !r.recordId))
            throw Error("Salesforce did not return the complete history receipt. Retry Save history; exact messages will not duplicate.");
          const full = rows.map((r, i) => ({...r, body: batch[i].body, hasFullBody: false}));
          pending = pending.slice(batch.length);
          store(); failure = ""; notify(full);
        }
      }).catch((error) => { failure = error?.body?.message || error.message || String(error); notify(); throw error; })
        .finally(() => { running = null; });
      return running;
    },
  };
  if (key) queues.set(key, queue);
  return queue;
}
