import { salesforceInstructions } from "./salesforce-runtime.js";
export const AGENT_RESPONSE_LIMIT = 14000;

export function agentResponseInstructions(reminder = false) {
  const rule =
    "AGENT RESPONSE LIMIT — EVERY ROUND: NEVER exceed 14,000 characters per response, including JSON escaping, fences and prose. Count characters, not tokens; leave a safety margin. Split larger replies into TWO separate responses (more only if two cannot fit), never truncate or combine both parts in one response. ";
  if (reminder)
    return (
      rule +
      "Use the taught atlas-response-part envelopes for JSON; preserve one logical proposal, not independent batches. Label plain-text parts.\n" +
      salesforceInstructions()
    );
  return (
    salesforceInstructions() +
    rule +
    `Atlas sends 100,000 characters by default; that INPUT limit does not raise your output limit. Label plain-text parts. For ANY JSON format (including ONE-object formats), serialize the complete object, divide its text into fragments and send ONE envelope per response:
{"type":"atlas-response-part","id":"unique-reply-id","part":1,"total":2,"text":"FIRST FRAGMENT OF SERIALIZED JSON"}
Use the same id/total and consecutive part numbers; new id for revisions. Concatenating decoded text must restore the exact original JSON. Count the ENTIRE escaped envelope against 14,000. I paste all envelopes on separate lines in the SAME JSON box, retaining earlier parts. Atlas reassembles and validates/reviews once, only when complete. Never split a ticket batch into independent submissions or reuse stale source hashes across approvals.\n`
  );
}

export function parseAgentJSON(text) {
  if (typeof text !== "string" || text.length > 8 * 1024 * 1024)
    throw Error("Agent JSON exceeds 8 MB. Ask for a smaller batch.");
  // Read complete top-level objects, optionally individually fenced. Braces and
  // fence-like text inside JSON strings remain literal data.
  const values = [];
  let rest = text.trim();
  while (rest) {
    const fence = rest.match(/^```(?:json)?\s*\n/i);
    if (fence) rest = rest.slice(fence[0].length);
    if (rest[0] !== "{")
      throw Error(
        "Invalid JSON: paste only a JSON object or response-part envelopes.",
      );
    let depth = 0,
      quoted = false,
      escaped = false,
      end = -1;
    for (let i = 0; i < rest.length; i++) {
      const ch = rest[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') quoted = false;
      } else if (ch === '"') quoted = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) {
        end = i + 1;
        break;
      }
    }
    if (end < 0) throw Error("Invalid JSON: incomplete object.");
    const raw = rest.slice(0, end);
    let length = raw.length + (fence ? fence[0].length : 0);
    rest = rest.slice(end);
    if (fence) {
      const closing = rest.match(/^\s*```/);
      if (!closing) throw Error("Invalid JSON: missing closing fence.");
      length += closing[0].length;
      rest = rest.slice(closing[0].length);
    }
    values.push({ value: JSON.parse(raw), length });
    rest = rest.trimStart();
    if (values.length > 1000)
      throw Error("Too many response parts; use a smaller batch.");
  }
  if (!values.length) throw Error("Invalid JSON: paste the agent response.");
  if (values.length === 1 && values[0].value.type !== "atlas-response-part")
    return values[0].value;
  const first = values[0].value,
    parts = new Map();
  for (const { value: v, length } of values) {
    if (
      v.type !== "atlas-response-part" ||
      Object.keys(v).some(
        (key) => !["type", "id", "part", "total", "text"].includes(key),
      ) ||
      typeof v.id !== "string" ||
      !/^[a-zA-Z0-9_-]{1,80}$/.test(v.id) ||
      !Number.isInteger(v.total) ||
      v.total < 2 ||
      v.total > 1000 ||
      !Number.isInteger(v.part) ||
      v.part < 1 ||
      v.part > v.total ||
      typeof v.text !== "string" ||
      !v.text
    )
      throw Error(
        "Invalid response part: use type, id, part, total (2–1000) and nonempty text.",
      );
    if (length > AGENT_RESPONSE_LIMIT)
      throw Error(
        "Each agent response part must fit 14,000 characters, including JSON escaping and fences.",
      );
    if (v.id !== first.id || v.total !== first.total)
      throw Error(
        "All response parts must use the same id and total. Do not mix replies.",
      );
    if (parts.has(v.part))
      throw Error("Duplicate response part. Keep each part exactly once.");
    parts.set(v.part, v.text);
  }
  if (parts.size !== first.total)
    throw Error(
      `Incomplete response (${parts.size}/${first.total} parts): keep earlier parts and paste the remaining responses below them in this same box. Nothing applied.`,
    );
  const joined = Array.from({ length: first.total }, (_, i) =>
    parts.get(i + 1),
  ).join("");
  const result = JSON.parse(joined);
  if (
    !result ||
    typeof result !== "object" ||
    Array.isArray(result) ||
    result.type === "atlas-response-part"
  )
    throw Error(
      "Response parts must reconstruct one original JSON object, not nested envelopes.",
    );
  return result;
}
