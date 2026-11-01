import { LIMIT_REMINDER } from "./protocol";

/** The envelope is only a proposal. Apex validates it again and stores the exact review. */
export function checkJiraWrite(message, conversationId) {
  const allowed = new Set(["type", "requestId", "operationId", "operation", "issueKey", "fields", "body", "transitionId"]);
  if (!message || Object.keys(message).some((key) => !allowed.has(key)))
    throw Error("A Jira proposal cannot set URLs, headers, credentials, approval or extra fields.");
  if (message.type !== "atlas-jira-write" || message.requestId !== conversationId)
    throw Error("A Jira proposal must include this conversation's exact requestId.");
  if (typeof message.operationId !== "string" || !/^[A-Za-z0-9_-]{1,80}$/.test(message.operationId))
    throw Error("Include a stable operationId of 1–80 letters, digits, underscores or hyphens. Reuse it only for the same exact operation.");
  if (!["create", "update", "comment", "transition"].includes(message.operation))
    throw Error("Jira supports create, update, comment or transition, one operation per review.");
  if (message.operation !== "create" && (typeof message.issueKey !== "string" || !/^[A-Z][A-Z0-9_]*-\d+$/i.test(message.issueKey)))
    throw Error("Use a real Jira issueKey, not an Atlas ticket ID.");
  const perOperation = {
    create: ["fields"], update: ["issueKey", "fields"],
    comment: ["issueKey", "body"], transition: ["issueKey", "transitionId"],
  }[message.operation];
  const payloadKeys = ["issueKey", "fields", "body", "transitionId"];
  if (payloadKeys.some((key) => Object.hasOwn(message, key) && !perOperation.includes(key)))
    throw Error("Send only the fields used by this Jira operation. Nothing was sent.");
  if (["create", "update"].includes(message.operation) && (!message.fields || typeof message.fields !== "object" || Array.isArray(message.fields) || !Object.keys(message.fields).length))
    throw Error("A Jira create or update needs a nonempty fields object with exact Jira field IDs and typed values.");
  if (message.operation === "comment" && (typeof message.body !== "string" || !message.body.trim()))
    throw Error("A Jira comment needs a nonempty plain-text body.");
  if (message.operation === "transition" && (typeof message.transitionId !== "string" || !/^\d+$/.test(message.transitionId)))
    throw Error("Use the transitionId returned by Jira, not a status label.");
  const request = { requestId: message.operationId, operation: message.operation };
  for (const key of perOperation) if (Object.hasOwn(message, key)) request[key] = message[key];
  if (JSON.stringify(request).length > 60000) throw Error("Keep one Jira proposal below 60,000 characters; split independent operations for separate review.");
  return request;
}

/** Queued and unknown are deliberately not reported as confirmed Jira writes. */
export function jiraWriteReply(operation, conversationId) {
  const notes = {
    reviewed: "Not sent to Jira. The exact request is waiting for human approval.",
    queued: "Approved and queued, but Jira has not confirmed success. Check this operation; do not resubmit.",
    succeeded: "Jira confirmed this operation. This is not a Salesforce metadata deployment.",
    failed: "The operation failed. Read the diagnostic before proposing a correction for a new review.",
    invalidated: "The reviewed operation is no longer valid. Nothing was sent by this review; prepare and review it again.",
    unknown: "The outcome is UNKNOWN. Jira may have applied this operation. Check Jira and reconcile before any further write. Never blindly resend or invent a new operationId to retry it.",
  };
  return JSON.stringify({
    type: "atlas-jira-write-result", requestId: conversationId,
    operationId: operation.requestId, receiptId: operation.id,
    state: operation.state, operation: operation.operation,
    confirmed: operation.state === "succeeded", result: operation.result || null,
    message: operation.message || "", note: notes[operation.state] || "The outcome is not confirmed. Check this operation; do not resubmit.",
  }, null, 2) + "\n\n" + LIMIT_REMINDER;
}
