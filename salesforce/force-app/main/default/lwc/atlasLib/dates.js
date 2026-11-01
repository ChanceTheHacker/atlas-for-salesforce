export function validDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const date = new Date(value + "T12:00:00Z");
  return (
    Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
  );
}

export function localDate(reference = new Date()) {
  return [
    reference.getFullYear(),
    String(reference.getMonth() + 1).padStart(2, "0"),
    String(reference.getDate()).padStart(2, "0"),
  ].join("-");
}

/** Five weekdays from today; holidays and team capacity are unknown. */
export function suggestedDueDate(reference = new Date()) {
  const date = new Date(reference.getTime());
  date.setHours(12, 0, 0, 0);
  for (let days = 0; days < 5; ) {
    date.setDate(date.getDate() + 1);
    if (date.getDay() !== 0 && date.getDay() !== 6) days++;
  }
  return {
    dueDate: localDate(date),
    dueDateSource: "suggested",
    dueDateNote: "Atlas default: 5 weekdays from " + localDate(reference),
  };
}

const MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split(" ");

/** Jira CSV dates: ISO, 14/Oct/26, 14/Oct/2026 10:15 AM, 2026-10-14 10:15. */
export function parseJiraDate(value) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  const iso = text.slice(0, 10);
  if (validDate(iso)) return iso;
  const m = /^(\d{1,2})\/([a-z]{3})\/(\d{2}|\d{4})\b/i.exec(text);
  if (m) {
    const month = MONTHS.indexOf(m[2].toLowerCase()) + 1;
    const year = m[3].length === 2 ? "20" + m[3] : m[3];
    const date = `${year}-${String(month).padStart(2, "0")}-${m[1].padStart(2, "0")}`;
    return validDate(date) ? date : "";
  }
  return "";
}

/** Jira CSV date-times as ISO 8601 for Salesforce, or "" when unreadable. */
export function parseJiraDateTime(value) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  const m =
    /^(\d{1,2})\/([a-z]{3})\/(\d{2}|\d{4})(?:\s+(\d{1,2}):(\d{2})(?:\s*([AP]M))?)?$/i.exec(
      text,
    );
  if (m) {
    const date = parseJiraDate(text);
    if (!date) return "";
    let hour = Number(m[4] || 0);
    if (m[6]) hour = (hour % 12) + (m[6].toUpperCase() === "PM" ? 12 : 0);
    const local = new Date(
      `${date}T${String(hour).padStart(2, "0")}:${m[5] || "00"}:00`,
    );
    return Number.isFinite(local.getTime()) ? local.toISOString() : "";
  }
  const parsed = new Date(text.replace(" ", "T"));
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : "";
}
