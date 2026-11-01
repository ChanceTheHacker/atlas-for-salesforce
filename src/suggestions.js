import { taskRecipe } from "./recipes.js";

const stop = new Set(
  "a an the this that these those to of and or in on with for from how what why when where which does do is are was be not it its i me my we our you please explain help need want should can could would file files source code apex lwc flow salesforce class public private return const import export true false null void static string new get set".split(
    " ",
  ),
);
export function words(text) {
  return [
    ...new Set(
      text
        .replace(/([a-z\d])([A-Z])/g, "$1 $2")
        .toLowerCase()
        .match(/[a-z][a-z0-9]*(?:__[a-z]+)?/g) || [],
    ),
  ].filter((w) => w.length > 2 && !stop.has(w));
}
export function indexForSuggestions(f) {
  f.searchTerms = {
    name: words(
      [f.path, f.objectName, f.label, ...f.symbols.map((s) => s.name)]
        .filter(Boolean)
        .join(" "),
    ),
    facts: words([f.description, ...f.facts, ...f.objects].join(" ")),
    code: words(f.text),
  };
}
export function suggestFiles(state, limit = 20) {
  const recipe = taskRecipe(state.book);
  const question = [
    state.book.question,
    state.book.constraints,
    ...Object.values(state.book.task || {}),
  ].join(" ");
  const baseTerms = words(question);
  const glossary = state.book.brief?.glossary;
  const aliases = glossary?.enabled
    ? glossary.text
        .split("\n")
        .filter((line) => words(line).some((t) => baseTerms.includes(t)))
        .join(" ")
    : "";
  const terms = words(question + " " + aliases);
  const selected = new Set(state.book.pack.map((p) => p.path));
  const scored = new Map();
  const add = (f, score, reason) => {
    if (!f || f.state !== "indexed") return;
    const old = scored.get(f.path);
    if (!old || score > old.score)
      scored.set(f.path, {
        path: f.path,
        score,
        reason,
        tokens: Math.ceil(f.text.length / 4),
      });
  };
  for (const f of state.files) {
    const idx = f.searchTerms;
    if (!idx) continue;
    const n = state.book.notes[f.path] || {};
    const groups = state.book.groups.filter((g) => g.paths.includes(f.path));
    const contextual = words(
      [
        n.purpose,
        n.notes,
        n.tags,
        ...groups.map((g) => g.name + " " + g.description),
      ].join(" "),
    );
    let score = 0;
    const reasons = [];
    for (const t of terms) {
      const weight = idx.name.includes(t)
        ? 12
        : contextual.includes(t)
          ? 10
          : idx.facts.includes(t)
            ? 7
            : idx.code.includes(t)
              ? 2
              : 0;
      if (weight) {
        score += weight;
        reasons.push(t);
      }
    }
    if (score >= 4) {
      if (f.isTest && ["debug", "refactor", "feature"].includes(recipe.key))
        score += 10;
      if (f.type === "Evidence" && recipe.key === "debug") score += 12;
      if (
        recipe.key === "feature" &&
        /permission|validation|recordtype|requirement/i.test(f.path)
      )
        score += 10;
      add(
        f,
        score,
        `${recipe.label} · Matches: ${reasons.slice(0, 5).join(", ")}`,
      );
    }
  }
  // Bounded traversal in both directions: task context, not a recursive project dump.
  const seeds = [...scored.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, 6)
    .map((s) => s.path);
  let frontier = new Set(
    [...seeds, ...selected]
      .map((p) => state.byPath.get(p)?.entityId)
      .filter(Boolean),
  );
  const visited = new Set();
  const adjacency = new Map();
  for (const edge of state.edges) {
    for (const id of new Set([edge.from, edge.to])) {
      if (!adjacency.has(id)) adjacency.set(id, []);
      adjacency.get(id).push(edge);
    }
  }
  const hops = recipe.key === "explain" ? 1 : 2;
  for (let depth = 0; depth < hops; depth++) {
    const next = new Set();
    for (const id of frontier) {
      if (visited.has(id)) continue;
      visited.add(id);
      const unit = state.entityMap.get(id);
      if (unit?.type !== "Object")
        for (const f of unit?.files || [])
          add(f, 8, `Companion file: ${unit.name}`);
      for (const e of adjacency.get(id) || []) {
        const outgoing = e.from === id;
        const targetId = outgoing ? e.to : e.from;
        const target = state.entityMap.get(targetId);
        const files =
          outgoing && e.targetPaths?.length
            ? e.targetPaths.map((p) => state.byPath.get(p))
            : target?.files || [];
        for (const f of files) {
          const weight = f?.isTest
            ? 20
            : !outgoing && recipe.key === "refactor"
              ? 18
              : 12;
          add(
            f,
            weight - depth * 3,
            `${recipe.label} · ${outgoing ? "Dependency" : "Caller / consumer"} of ${unit?.name}: ${e.kind} (${e.confidence}; hop ${depth + 1})`,
          );
        }
        // A shared object is a useful route to automation, but not to other objects' neighborhoods.
        if (unit?.type !== "Object" || target?.type !== "Object")
          next.add(targetId);
      }
    }
    frontier = next;
  }
  return [...scored.values()]
    .map((s) => {
      const f = state.byPath.get(s.path);
      const name =
        f.entityName ||
        state.entityMap.get(f.entityId)?.name ||
        f.name.replace(/\..*$/, "");
      const explicit =
        name &&
        question
          .toLowerCase()
          .match(/[a-z0-9_]+/g)
          ?.includes(name.toLowerCase());
      return {
        ...s,
        priority:
          explicit &&
          !f.isTest &&
          ["Apex", "LWC", "Flow", "Object"].includes(f.type)
            ? "essential"
            : f.type === "Other"
              ? "background"
              : "supporting",
      };
    })
    .filter((s) => !selected.has(s.path))
    .sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))
    .slice(0, limit);
}
