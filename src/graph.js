export function buildGraph(S) {
  const entities = new Map(),
    dirOf = (f) => f.path.split("/").slice(0, -1).join("/"),
    lwcDirs = new Set(S.files.filter((f) => f.type === "LWC").map(dirOf)),
    bundleRoots = new Set(
      S.files
        .filter(
          (f) =>
            f.type === "LWC" &&
            (/\.js-meta\.xml$/i.test(f.name) ||
              /\bextends\s+LightningElement\b/.test(f.text)),
        )
        .map(dirOf),
    );
  for (const f of S.files) {
    if (
      f.type === "Other" &&
      lwcDirs.has(dirOf(f)) &&
      /\.(html|css|xml|js|ts)$/i.test(f.path)
    )
      f.type = "LWC";
    let id = "",
      name = "";
    if (f.type === "LWC") {
      const p = f.path.split("/"),
        i = p.findIndex((x) => x.toLowerCase() === "lwc");
      let base = "";
      for (let depth = p.length - 1; depth > 0; depth--) {
        const candidate = p.slice(0, depth).join("/");
        if (bundleRoots.has(candidate)) {
          base = candidate;
          break;
        }
      }
      base =
        base ||
        (i >= 0 && p.length > i + 2
          ? p.slice(0, i + 2).join("/")
          : p.slice(0, -1).join("/"));
      id = "LWC:" + base;
      name = base.split("/").at(-1) || f.name.replace(/\..*$/, "");
    } else if (f.type === "Apex") {
      id = "Apex:" + f.path.replace(/-meta\.xml$/i, "");
      name =
        f.entityName || f.name.replace(/\.(cls|trigger)(-meta\.xml)?$/i, "");
    } else if (f.type === "Object") {
      name = f.objectName;
      id = "Object:" + f.objectBase + ":" + name;
    } else if (f.type === "Permission") {
      id = "Permission:" + f.path;
      name = f.entityName || f.name;
    } else if (f.type === "Flow") {
      id = "Flow:" + f.path;
      name = f.entityName || f.name;
    }
    if (id) {
      f.entityId = id;
      if (!entities.has(id))
        entities.set(id, { id, name, type: f.type, files: [] });
      entities.get(id).files.push(f);
    }
  }
  S.entities = Array.from(entities.values()).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
  S.entityMap = entities;
  const byName = new Map();
  for (const e of S.entities) {
    const k = e.type + ":" + e.name.toLowerCase();
    if (!byName.has(k)) byName.set(k, []);
    byName.get(k).push(e);
  }
  const edges = [],
    refs = [],
    seen = new Set();
  for (const f of S.files) {
    for (const r of f.refs) {
      let type =
        r.targetType ||
        (/Apex/.test(r.kind)
          ? "Apex"
          : /Flow|Subflow/.test(r.kind) && !/screen/.test(r.kind)
            ? "Flow"
            : "LWC");
      const targetName = type === "Object" ? r.target.split(".")[0] : r.target;
      let candidates = byName.get(type + ":" + targetName.toLowerCase()) || [];
      if (!candidates.length && type === "Apex" && r.target.includes("."))
        candidates =
          byName.get(type + ":" + r.target.split(".").at(-1).toLowerCase()) ||
          [];
      if (!candidates.length && r.kind === "Apex reference") {
        const objects = byName.get("Object:" + r.target.toLowerCase()) || [];
        if (objects.length) {
          type = "Object";
          candidates = objects;
        }
      }
      let targetPaths = [];
      const fieldName =
        type === "Object" ? r.target.split(".").slice(1).join(".") : "";
      const fieldMissing =
        fieldName &&
        candidates.length === 1 &&
        !candidates[0].files.some((f) =>
          f.fields?.some((n) => n.toLowerCase() === fieldName.toLowerCase()),
        );
      if (candidates.length === 1 && type === "Object" && !fieldMissing)
        targetPaths = candidates[0].files
          .filter(
            (f) =>
              !fieldName ||
              f.metadataKind === "CustomObject" ||
              f.fields?.some(
                (n) => n.toLowerCase() === fieldName.toLowerCase(),
              ),
          )
          .map((f) => f.path);
      if (
        r.confidence === "Inferred" &&
        !candidates.length &&
        type !== "Object"
      )
        continue;
      const out = {
        ...r,
        file: f.path,
        from: f.entityId,
        targetPaths,
        to: candidates.length === 1 && !fieldMissing ? candidates[0].id : "",
        resolution: fieldMissing
          ? "Field metadata not in folder"
          : candidates.length === 1
            ? "Resolved"
            : candidates.length
              ? "Ambiguous"
              : "Not in folder",
      };
      if (out.to && out.to === out.from && r.kind !== "Lookup relationship")
        continue;
      refs.push(out);
      if (out.to && out.from) {
        const k = [out.from, out.to, out.kind, out.detail].join("|");
        if (!seen.has(k)) {
          seen.add(k);
          edges.push(out);
        }
      }
    }
  }
  S.edges = edges;
  S.refs = refs;
}
