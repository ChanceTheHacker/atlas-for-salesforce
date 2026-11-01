// Bounded declarations only: never guess an end from the next method name.
function docStart(text, offset, line) {
  let end = offset;
  while (end > 0 && /\s/.test(text[end - 1])) end--;
  if (text.slice(end - 2, end) !== "*/") return line;
  const start = text.lastIndexOf("/*", end - 2);
  return start >= 0 && text[start + 2] === "*"
    ? line - (text.slice(start, offset).match(/\n/g) || []).length
    : line;
}

export function apexSnippets(text) {
  const clean = text.replace(
    /\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|$)|'(?:\\[\s\S]|[^'\\])*'|"(?:\\[\s\S]|[^"\\])*"/g,
    (s) => s.replace(/[^\n]/g, " "),
  );
  const tokens = [];
  let line = 1;
  for (const m of clean.matchAll(/\n|[A-Za-z_$][\w$]*|[^\s]/g)) {
    if (m[0] === "\n") line++;
    else tokens.push({ value: m[0], offset: m.index, line });
  }
  const pairs = new Map(),
    stack = [];
  for (let i = 0; i < tokens.length; i++) {
    const v = tokens[i].value;
    if (v === "'" || v === '"') return [];
    if ("({[".includes(v)) stack.push(i);
    else if (")}]".includes(v)) {
      const open = stack.pop();
      if (
        open === undefined ||
        "({[".indexOf(tokens[open].value) !== ")}]".indexOf(v)
      )
        return [];
      pairs.set(open, i);
    }
  }
  if (stack.length) return [];
  const snippets = [],
    value = (i) => tokens[i]?.value;
  function members(from, to, owner = "") {
    let start = from;
    while (start < to) {
      let boundary = start,
        params = -1;
      for (; boundary < to; boundary++) {
        if (["{", ";"].includes(value(boundary))) break;
        if (["(", "["].includes(value(boundary))) {
          const end = pairs.get(boundary);
          if (value(boundary) === "(" && ["{", ";"].includes(value(end + 1)))
            params = boundary;
          boundary = end;
        }
      }
      if (boundary >= to) break;
      const end = value(boundary) === "{" ? pairs.get(boundary) : boundary;
      const header = tokens.slice(start, boundary).map((t) => t.value);
      const type = header.findIndex((v) =>
        ["class", "interface", "enum"].includes(v.toLowerCase()),
      );
      if (type >= 0 && value(boundary) === "{") {
        const name = header[type + 1];
        members(boundary + 1, end, owner ? owner + "." + name : name);
      } else if (
        owner &&
        params > start &&
        /^[A-Za-z_]\w*$/.test(value(params - 1))
      ) {
        let declaration = start;
        while (value(declaration) === "@") {
          declaration += 2;
          while (value(declaration) === ".") declaration += 2;
          if (value(declaration) === "(")
            declaration = pairs.get(declaration) + 1;
        }
        const prefix = tokens
          .slice(declaration, params - 1)
          .map((t) => t.value);
        const name = value(params - 1);
        if (
          declaration < params &&
          !prefix.some((v) =>
            ["=", "new", "return", "throw"].includes(v.toLowerCase()),
          ) &&
          (prefix.length ||
            name.toLowerCase() === owner.split(".").at(-1).toLowerCase())
        ) {
          snippets.push({
            name,
            qualifiedName: owner + "." + name,
            kind: "Method",
            start: docStart(text, tokens[start].offset, tokens[start].line),
            line: tokens[declaration].line,
            end: tokens[end].line,
          });
        }
      }
      start = end + 1;
    }
  }
  members(0, tokens.length);
  return snippets;
}

export function jsSnippets(ast, text) {
  if (ast.errors?.length) return [];
  const snippets = [],
    qualify = (owner, name) => (owner ? owner + "." + name : name);
  const keyName = (node) =>
    !node.computed && (node.key?.name || node.key?.value);
  function walk(node, owner = "", binding = "", declaration = node) {
    if (!node || typeof node !== "object") return;
    if (["ClassDeclaration", "ClassExpression"].includes(node.type)) {
      const name = node.id?.name || binding;
      for (const member of node.body.body)
        walk(member, name ? qualify(owner, name) : owner);
      return;
    }
    if (node.type === "VariableDeclaration") {
      for (const d of node.declarations)
        walk(
          d.init,
          owner,
          d.id.name,
          node.declarations.length === 1 ? node : d,
        );
      return;
    }
    if (
      ["ClassProperty", "ClassPrivateProperty", "ObjectProperty"].includes(
        node.type,
      )
    ) {
      walk(node.value, owner, keyName(node), node);
      return;
    }
    if (node.type === "ObjectExpression") {
      for (const p of node.properties)
        walk(p, binding ? qualify(owner, binding) : owner);
      return;
    }
    let name;
    if (["ClassMethod", "ObjectMethod", "TSDeclareMethod"].includes(node.type))
      name = keyName(node);
    else if (
      node.type === "FunctionDeclaration" ||
      node.type === "TSDeclareFunction"
    )
      name = node.id?.name;
    else if (
      ["ArrowFunctionExpression", "FunctionExpression"].includes(node.type)
    )
      name = binding || node.id?.name;
    if (typeof name === "string" && /^[A-Za-z_$][\w$]*$/.test(name)) {
      const qualifiedName = qualify(owner, name);
      snippets.push({
        name,
        qualifiedName,
        kind:
          node.kind === "get" || node.kind === "set"
            ? node.kind + " accessor"
            : "Method / function",
        start: docStart(text, declaration.start, declaration.loc.start.line),
        line: node.loc.start.line,
        end: declaration.loc.end.line,
      });
      owner = qualifiedName;
    }
    for (const [key, value] of Object.entries(node)) {
      if (
        [
          "loc",
          "comments",
          "leadingComments",
          "trailingComments",
          "tokens",
          "errors",
        ].includes(key)
      )
        continue;
      if (Array.isArray(value)) value.forEach((child) => walk(child, owner));
      else if (value && typeof value === "object") walk(value, owner);
    }
  }
  walk(ast);
  return snippets.sort((a, b) => a.start - b.start);
}

export function resolveSnippet(file, symbol, contextLines = 3) {
  const normalize = (name) =>
    /\.(cls|trigger)$/i.test(file.path) ? name.toLowerCase() : name;
  const matches = (file.snippets || []).filter((s) =>
    [s.name, s.qualifiedName].some(
      (name) => normalize(name) === normalize(symbol),
    ),
  );
  if (!matches.length)
    return {
      ranges: [],
      issue: `Symbol not resolved in ${file.path}: ${symbol}. Use a detected method name, explicit start/end lines, or request full source; no full-file fallback was included.`,
    };
  if (new Set(matches.map((s) => normalize(s.qualifiedName))).size > 1)
    return {
      ranges: [],
      issue: `Ambiguous symbol in ${file.path}: ${symbol}. Use a qualified name: ${[...new Set(matches.map((s) => s.qualifiedName))].join(", ")}.`,
    };
  return {
    ranges: matches.map((s) => ({
      mode: "lines",
      start: Math.max(1, s.start - contextLines),
      end: Math.min(file.lines || 1, s.end + contextLines),
      symbol: s.qualifiedName,
      declarationStart: s.start,
      declarationEnd: s.end,
      contextLines,
    })),
  };
}
