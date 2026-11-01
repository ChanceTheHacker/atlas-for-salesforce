// How Atlas and the agent exchange messages. The agent never reaches Salesforce:
// the user copies Atlas prompts into the agent chat and pastes the agent's JSON back.

/** Hard limit for one agent response, including JSON escaping and code fences. */
export const AGENT_LIMIT = 14000;
/** Default size of one Atlas message to the agent. */
export const DEFAULT_REPLY_LIMIT = 100000;

export const MESSAGE_TYPES = [
  "atlas-request",
  "atlas-backup",
  "atlas-change",
  "atlas-tickets",
  "atlas-assign",
  "atlas-files",
  "atlas-uat-plan",
  "atlas-questions",
  "atlas-users",
  "atlas-context",
  "atlas-jira-refresh",
  "atlas-jira-write",
];

export function replyLimit(value) {
  const n = Number(value);
  return Number.isInteger(n) && n >= 1000 && n <= 1000000
    ? n
    : DEFAULT_REPLY_LIMIT;
}

/** One reminder line that ends every message Atlas sends to the agent. */
export const LIMIT_REMINDER =
  'REPLY LIMIT: 14,000 characters maximum, including escaping, fences and prose, also in Files and UAT. Aim below 12,000. Serialize and validate JSON. Count final text, not unescaped content, with code if available. Use a fenced json code block. Long JSON: separately serialized atlas-response-part envelopes, ONE per response; STOP; wait for Continue. Never truncate content. For source edits, preserve exact find text: copy from the latest backup/retrieve, never from memory; if missing, request "resend":true and wait.';

/**
 * Reads the agent's pasted reply: one JSON object, or atlas-response-part envelopes
 * that rebuild one object. Prose before the JSON and after it is ignored.
 */
export function parseAgentJSON(text) {
  if (typeof text !== "string" || !text.trim())
    throw Error("Paste the agent's reply first.");
  if (text.length > 8 * 1024 * 1024)
    throw Error("The pasted text is larger than 8 MB. Ask the agent for less.");
  const start = text.search(/^\s*(```|\{)/m);
  if (start < 0)
    throw Error(
      "No JSON found. Paste the agent's JSON message (it starts with { ).",
    );
  let rest = text.slice(start).trim();
  const values = [];
  while (rest) {
    const fence = rest.match(/^```[a-z0-9]*[^\S\n]*\n\s*/i);
    if (fence) rest = rest.slice(fence[0].length);
    if (rest[0] !== "{") {
      // A code block that is not JSON (a shell command, a code sample) is skipped whole.
      const closing = fence ? rest.search(/^\s*```/m) : -1;
      if (closing >= 0) {
        rest = rest.slice(closing).replace(/^\s*```/, "");
        const next = rest.search(/^\s*(```|\{)/m);
        rest = next < 0 ? "" : rest.slice(next).trim();
        continue;
      }
      if (values.length) break;
      throw Error(fence ? "No JSON found after the code fence." : "No JSON found. Paste the agent's JSON message (it starts with { ).");
    }
    const end = objectEnd(rest);
    if (end < 0)
      throw Error(
        "The JSON is incomplete. Paste the whole message; if the agent sent parts, paste every part.",
      );
    const raw = rest.slice(0, end);
    let size = raw.length + (fence ? fence[0].length : 0);
    rest = rest.slice(end);
    if (fence) {
      const closing = rest.match(/^\s*```/);
      if (closing) {
        size += closing[0].length;
        rest = rest.slice(closing[0].length);
      }
    }
    let value;
    try {
      value = JSON.parse(raw);
    } catch (e) {
      throw Error("The JSON is not valid: " + e.message);
    }
    values.push({ value, size });
    // Prose between parts is allowed; skip to the next JSON object or fence.
    const next = rest.search(/^\s*(```|\{)/m);
    rest = next < 0 ? "" : rest.slice(next).trim();
    if (values.length > 1000) throw Error("Too many parts in one paste.");
  }
  if (!values.length)
    throw Error(
      "No JSON found. Paste the agent's JSON message (it starts with { ).",
    );
  if (values.length === 1 && values[0].value?.type !== "atlas-response-part")
    return values[0].value;
  return joinParts(values);
}

/** Index just past the closing brace of the object that starts at 0, or -1. */
function objectEnd(text) {
  let depth = 0,
    quoted = false,
    escaped = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') quoted = false;
    } else if (ch === '"') quoted = true;
    else if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) return i + 1;
  }
  return -1;
}

function joinParts(values) {
  const first = values[0].value;
  const parts = new Map();
  for (const { value: v, size } of values) {
    if (
      !v ||
      v.type !== "atlas-response-part" ||
      typeof v.id !== "string" ||
      !v.id ||
      !Number.isInteger(v.part) ||
      !Number.isInteger(v.total) ||
      v.total < 1 ||
      v.part < 1 ||
      v.part > v.total ||
      typeof v.text !== "string"
    )
      throw Error(
        "Paste one JSON message, or atlas-response-part messages that each have id, part, total and text.",
      );
    if (v.total > 1000) throw Error("One message can contain at most 1000 parts. Ask the agent to split the work into smaller messages.");
    if (v.id !== first.id || v.total !== first.total)
      throw Error(
        "These parts belong to different messages (their id or total differ). Paste the parts of one message only.",
      );
    if (parts.has(v.part)) throw Error(`Part ${v.part} was pasted twice.`);
    if (size > AGENT_LIMIT + 200)
      throw Error(
        `Part ${v.part} is ${size.toLocaleString()} characters, over the 14,000 limit, and may have been cut off. Ask the agent to resend it smaller.`,
      );
    parts.set(v.part, v.text);
  }
  if (parts.size !== first.total) {
    const missing = [];
    for (let i = 1; i <= first.total; i++) if (!parts.has(i)) missing.push(i);
    throw Error(
      `Part ${missing.join(", ")} of ${first.total} is missing. Keep the parts you pasted and add the rest below them.`,
    );
  }
  let joined = "";
  for (let i = 1; i <= first.total; i++) joined += parts.get(i);
  let result;
  try {
    result = JSON.parse(joined);
  } catch (e) {
    throw Error(
      "The parts joined together are not valid JSON (" +
        e.message +
        "). Ask the agent to resend all parts.",
    );
  }
  if (!result || typeof result !== "object" || Array.isArray(result))
    throw Error("The parts must rebuild one JSON object.");
  return result;
}

/**
 * Splits a Atlas message that is longer than the user's limit into numbered parts
 * the agent can reassemble. Splits prefer line breaks.
 */
export function splitReply(full, limit) {
  const max = replyLimit(limit);
  if (full.length <= max) return [full];
  let hash = 2166136261;
  for (let i = 0; i < full.length; i++)
    hash = Math.imul(hash ^ full.charCodeAt(i), 16777619) >>> 0;
  const id = hash.toString(16).padStart(8, "0");
  const wrap = (text, part, total) =>
    `ATLAS MESSAGE ${id}, PART ${part} OF ${total}\n` +
    (part < total
      ? "This message is split into parts. Keep this part and reply only \"Received part " +
        part +
        '". Do not act until the last part arrives.\n'
      : "This is the last part. Join all parts in order (leave out these headers) and then act on the whole message.\n") +
    "--- BEGIN PART ---\n" +
    text +
    "\n--- END PART ---\n" +
    LIMIT_REMINDER;
  const room =
    max -
    Math.max(wrap("", 9998, 9999).length, wrap("", 9999, 9999).length);
  const chunks = [];
  for (let start = 0; start < full.length; ) {
    let end = Math.min(start + room, full.length);
    if (end < full.length) {
      const newline = full.lastIndexOf("\n", end - 1);
      if (newline >= start + room / 2) end = newline + 1;
      const code = full.charCodeAt(end - 1);
      if (code >= 0xd800 && code <= 0xdbff) end--;
    }
    chunks.push(full.slice(start, end));
    start = end;
  }
  return chunks.map((text, i) => wrap(text, i + 1, chunks.length));
}

/** The readable message inside an Apex or JavaScript error. */
export function errorMessage(error) {
  if (!error) return "Unknown error.";
  if (typeof error === "string") return error;
  const body = error.body;
  if (Array.isArray(body)) return body.map((b) => b.message).join(" ");
  return (
    body?.message ||
    body?.pageErrors?.[0]?.message ||
    error.message ||
    String(error)
  );
}
