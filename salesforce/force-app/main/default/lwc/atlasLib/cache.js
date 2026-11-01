// Research snapshots live only in this page's memory, never in persistent storage.
// Approval, identity checks and backups always use their authoritative server APIs.
const entries = new Map();
const epochs = new Map();
const MAX_ENTRIES = 80;
const MAX_CHARS = 4000000;
let chars = 0;

export function researchScope(boot) {
  return boot?.org?.id && boot?.user?.id ? `${boot.org.id}:${boot.user.id}` : null;
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
}
function remove(key) {
  const entry = entries.get(key);
  chars -= entry?.text?.length || 0;
  entries.delete(key);
}
export function invalidateResearch(scope) {
  if (!scope) return;
  epochs.set(scope, (epochs.get(scope) || 0) + 1);
  for (const [key, entry] of entries) if (entry.scope === scope) remove(key);
}
function lifetime(request) {
  if (request.op === "describe" || request.op === "metadata-types") return 300000;
  if (request.op === "retrieve" || request.op === "metadata-list") return 60000;
  // Jira capabilities can be disabled or redirected in another tab. Always ask the
  // server again, including tickets which may switch from the mirror to live Jira.
  if (["rest", "jira", "tickets"].includes(request.op)) return 0;
  return 30000;
}

export async function cachedResearch(scope, request, fetch, now = Date.now) {
  const {id, fresh, ...query} = request;
  const ttl = lifetime(request);
  if (!scope || !ttl) return {result: await fetch(), cache: {hit: false, fetchedAt: new Date(now()).toISOString()}};
  const key = JSON.stringify([scope, stable(query)]);
  const existing = entries.get(key);
  if (fresh !== true && existing && (existing.pending || existing.expires > now())) {
    entries.delete(key); entries.set(key, existing);
    const saved = existing.pending ? await existing.pending : existing;
    return {result: JSON.parse(saved.text), cache: {hit: true, fetchedAt: saved.fetchedAt, expiresAt: new Date(saved.expires).toISOString()}};
  }
  remove(key);
  const epoch = epochs.get(scope) || 0;
  const entry = {scope};
  entries.set(key, entry);
  while (entries.size > MAX_ENTRIES) remove(entries.keys().next().value);
  entry.pending = (async () => {
    try {
      const result = await fetch();
      if (epoch !== (epochs.get(scope) || 0)) throw Error("Salesforce changed during this read. Request the data again with fresh:true; the older result was not reused.");
      const text = JSON.stringify(result), fetchedAt = new Date(now()).toISOString(), expires = now() + ttl;
      const saved = {text, fetchedAt, expires};
      if (entries.get(key) === entry) {
        if (text.length <= MAX_CHARS && !result?.error && !result?.errorMessage) {
          Object.assign(entry, saved); chars += text.length;
          while (chars > MAX_CHARS) remove(entries.keys().next().value);
        } else remove(key);
      }
      return saved;
    } catch (error) {
      if (entries.get(key) === entry) remove(key);
      throw error;
    } finally { entry.pending = null; }
  })();
  const saved = await entry.pending;
  return {result: JSON.parse(saved.text), cache: {hit: false, fetchedAt: saved.fetchedAt, expiresAt: new Date(saved.expires).toISOString()}};
}
