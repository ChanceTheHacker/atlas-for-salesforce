export function analyzeObject(f, doc) {
  const root = doc.documentElement;
  const parts = f.path.split("/"),
    objectIndex = parts.findIndex((p) => p.toLowerCase() === "objects");
  const childKinds = [
    "CustomField",
    "ValidationRule",
    "RecordType",
    "FieldSet",
    "CompactLayout",
    "ListView",
    "BusinessProcess",
    "SharingReason",
    "Index",
  ];
  const kind = root.localName;
  if (kind !== "CustomObject" && !childKinds.includes(kind)) return;
  const children = (el) =>
    Array.from(el.childNodes || []).filter((n) => n.nodeType === 1);
  const value = (el, name) =>
    children(el)
      .find((n) => n.localName === name)
      ?.textContent.trim() || "";
  const all = (el, name) =>
    Array.from(el.getElementsByTagName("*")).filter(
      (n) => n.localName === name,
    );
  const objectName =
    objectIndex >= 0 && parts.length > objectIndex + 2
      ? parts[objectIndex + 1]
      : kind === "CustomObject"
        ? value(root, "fullName") ||
          f.name.replace(/\.object(?:-meta\.xml)?$/i, "")
        : parts.at(-3) || f.root;
  if (!objectName) {
    f.facts.push(
      "Object child metadata: select its parent object folder to identify its owner",
    );
    return;
  }
  f.type = "Object";
  f.objectName = objectName;
  f.objectBase =
    objectIndex >= 0 && parts.length > objectIndex + 2
      ? parts.slice(0, objectIndex + 2).join("/")
      : /\.object$/i.test(f.name)
        ? f.path
        : kind === "CustomObject"
          ? parts.slice(0, -1).join("/")
          : parts.slice(0, -2).join("/");
  f.label = value(root, "label");
  f.description = value(root, "description");
  f.metadataKind = kind;
  f.facts.push(`Object: ${objectName}`, `Metadata: ${kind}`);
  if (f.label) f.facts.push(`Label: ${f.label}`);
  f.fields = [];
  const fields =
    kind === "CustomField"
      ? [root]
      : children(root).filter((n) => n.localName === "fields");
  for (const field of fields) {
    const name =
      value(field, "fullName") || f.name.replace(/\.field-meta\.xml$/i, "");
    const type = value(field, "type");
    f.fields.push(name);
    f.symbols.push({
      name: `${objectName}.${name}`,
      kind: type || "Field",
      line: field.lineNumber || 1,
    });
    f.facts.push(`${name}: ${type || "Field"}`);
    for (const key of [
      "required",
      "unique",
      "externalId",
      "length",
      "precision",
      "scale",
      "formula",
      "defaultValue",
      "relationshipName",
      "deleteConstraint",
    ]) {
      const v = value(field, key);
      if (v) f.facts.push(`${name} ${key}: ${v}`);
    }
    for (const target of all(field, "referenceTo"))
      f.refs.push({
        kind: "Lookup relationship",
        target: target.textContent.trim(),
        line: target.lineNumber || 1,
        detail: `${objectName}.${name} (${type})`,
        confidence: "Direct",
        targetType: "Object",
      });
    const values = all(field, "value")
      .map((v) => value(v, "fullName"))
      .filter(Boolean);
    if (values.length) f.facts.push(`${name} picklist: ${values.join(", ")}`);
  }
  if (kind !== "CustomObject" && kind !== "CustomField") {
    f.symbols.push({
      name: value(root, "fullName") || f.name.replace(/\.[^.]+-meta\.xml$/, ""),
      kind,
      line: root.lineNumber || 1,
    });
  }
  for (const key of [
    "sharingModel",
    "deploymentStatus",
    "enableActivities",
    "enableHistory",
    "errorConditionFormula",
    "errorMessage",
    "active",
  ]) {
    const v = value(root, key);
    if (v) f.facts.push(`${key}: ${v}`);
  }
  for (const name of [
    "validationRules",
    "recordTypes",
    "fieldSets",
    "compactLayouts",
    "listViews",
  ]) {
    for (const node of children(root).filter((n) => n.localName === name))
      f.symbols.push({
        name: value(node, "fullName"),
        kind: name,
        line: node.lineNumber || 1,
      });
  }
}
