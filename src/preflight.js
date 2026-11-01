export function contextChecks(state, sections = [], header = "") {
  const warnings = [];
  for (const p of state.book.pack) {
    const f = state.byPath.get(p.path);
    if (!f || f.state !== "indexed") {
      warnings.push(
        `Source unavailable: ${p.path} (${f?.state || "missing from scan"}).`,
      );
      continue;
    }
    if (
      state.book.embedSource &&
      p.mode === "lines" &&
      (!p.hash ||
        p.hash !== f.hash ||
        p.start < 1 ||
        p.end > f.lines ||
        p.start > p.end)
    )
      warnings.push(
        `Stale or unverified excerpt: ${p.path}. Recheck its selected lines against the current file.`,
      );
    for (const r of state.refs.filter((r) => r.file === p.path && !r.to))
      warnings.push(
        `Unresolved dependency: ${p.path} → ${r.target} (${r.resolution}).`,
      );
    if (f.facts.some((s) => /could not be parsed|analysis unavailable/.test(s)))
      warnings.push(
        `Incomplete analysis: ${p.path}. Inspect the original source.`,
      );
  }
  const sensitive =
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:password|secret|api[_-]?key|access[_-]?token|client[_-]?secret)\b["']?\s*[:=]\s*["'][^"']{6,}|\bBearer\s+[A-Za-z0-9._-]{16,}|\bAKIA[A-Z0-9]{16}\b/i;
  const personal =
    /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){15,16}\b/i;
  const notes =
    header ||
    [state.book.projectNotes, state.book.question, state.book.constraints].join(
      "\n",
    );
  if (sensitive.test(notes))
    warnings.push(
      "Potentially sensitive content in outgoing task, brief, notes or map. Review before sharing.",
    );
  if (personal.test(notes))
    warnings.push(
      "Possible personal data / records in outgoing task, brief, notes or map. Review before sharing.",
    );
  sections.forEach((text, i) => {
    if (sensitive.test(text))
      warnings.push(
        `Potentially sensitive content: ${state.book.pack[i].path}. Review before sharing.`,
      );
    if (personal.test(text))
      warnings.push(
        `Possible personal data / records: ${state.book.pack[i].path}. Review before sharing.`,
      );
  });
  return [...new Set(warnings)];
}
