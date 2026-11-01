export const RECIPES = {
  debug: {
    label: "Fix a bug",
    needs:
      "implementation, callers, tests, automation, logs and reproduction evidence",
  },
  refactor: {
    label: "Refactor safely",
    needs:
      "implementation, callers/consumers, interfaces, tests and behavior to preserve",
  },
  feature: {
    label: "Add a feature",
    needs:
      "similar implementations, extension points, schema, validation, permissions, tests and acceptance criteria",
  },
  explain: {
    label: "Understand the system",
    needs: "entry points, dependencies, schema and business context",
  },
};
export function taskRecipe(book) {
  const aliases = { change: "feature", impact: "refactor", tests: "refactor" };
  let key = aliases[book.goal] || book.goal;
  if (key === "auto") {
    const text = [book.question, book.constraints].join(" ");
    key = /\b(refactor|rename|extract|restructure|migrate)\b/i.test(text)
      ? "refactor"
      : /\b(bug|fix|error|fail\w*|exception|broken|incorrect)\b/i.test(text)
        ? "debug"
        : /\b(add|implement|introduce|create|new feature)\b/i.test(text)
          ? "feature"
          : "explain";
  }
  key = Object.hasOwn(RECIPES, key) ? key : "explain";
  return { key, ...RECIPES[key] };
}

export function evidenceKind(path) {
  if (/\.(log|stacktrace)$/i.test(path)) return "Debug log / stack trace";
  if (/\.(diff|patch)$/i.test(path)) return "Before/after diff";
  if (/\.(csv|tsv|jsonl|ndjson)$/i.test(path)) return "Sample records";
  if (/(?:^|\/)(?:evidence|logs|samples)\/.*\.(txt|json|md)$/i.test(path))
    return "Supporting evidence";
  if (
    /(requirement|acceptance|repro|expected|actual).*\.(md|txt|json)$/i.test(
      path,
    )
  )
    return "Requirements / observations";
  return "";
}
