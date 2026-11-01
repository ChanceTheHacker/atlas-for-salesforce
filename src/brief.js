import { words } from "./suggestions.js";

export const BRIEF_FIELDS = {
  purpose: "System purpose",
  glossary: "Business terms → technical names",
  architecture: "Architecture and preferred patterns",
  invariants: "Behaviors that must not change",
  platform: "Platform constraints and integrations",
  testing: "Testing and definition of success",
};

export function blankBrief(raw = {}) {
  return Object.fromEntries(
    Object.keys(BRIEF_FIELDS).map((key) => [
      key,
      {
        text: typeof raw?.[key]?.text === "string" ? raw[key].text : "",
        scope: typeof raw?.[key]?.scope === "string" ? raw[key].scope : "",
        enabled: raw?.[key]?.enabled !== false,
      },
    ]),
  );
}

export function briefContext(book) {
  const terms = new Set(
    words(
      [book.question, book.constraints, ...book.pack.map((p) => p.path)].join(
        " ",
      ),
    ),
  );
  const included = [],
    omitted = [];
  for (const [key, label] of Object.entries(BRIEF_FIELDS)) {
    const section = book.brief?.[key];
    if (!section?.text.trim()) continue;
    const scopes = words(section.scope);
    if (
      section.enabled &&
      (!section.scope.trim() || scopes.some((t) => terms.has(t)))
    )
      included.push({ key, label, text: section.text });
    else omitted.push(label);
  }
  return { included, omitted };
}

export function briefText(book) {
  const { included, omitted } = briefContext(book);
  return (
    "\nREUSABLE PROJECT BRIEF\n" +
    (included
      .map(
        (s) =>
          `${s.label}:\n${s.text.length <= 1600 ? s.text : `Detailed section deferred (${s.text.length} characters). Request {"context":[{"type":"brief","name":${JSON.stringify(s.key)}}]}.`}`,
      )
      .join("\n\n") || "No applicable brief sections.") +
    (omitted.length
      ? `\nBrief sections omitted by scope or switch: ${omitted.join(", ")}.`
      : "") +
    "\n"
  );
}
