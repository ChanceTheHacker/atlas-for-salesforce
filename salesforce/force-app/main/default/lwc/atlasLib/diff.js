// Line diff (Myers) for the change review screen.

// Above this many changed lines the review shows the file as fully replaced.
const MAX_EDITS = 3000;

function myers(a, b) {
  const n = a.length,
    m = b.length,
    max = Math.min(n + m, MAX_EDITS),
    offset = max + 1;
  const v = new Int32Array(2 * max + 3);
  const trace = [];
  for (let d = 0; d <= max; d++) {
    // Only diagonals -d-1..d+1 matter at step d, so keep just that slice.
    trace.push(v.slice(offset - d - 1, offset + d + 2));
    for (let k = -d; k <= d; k += 2) {
      let x =
        k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])
          ? v[offset + k + 1]
          : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) return backtrack(trace, n, m);
    }
  }
  return [
    ...a.map((_, i) => ({ type: "del", a: i })),
    ...b.map((_, i) => ({ type: "add", b: i })),
  ];
}

function backtrack(trace, n, m) {
  let x = n,
    y = m;
  const ops = [];
  for (let d = trace.length - 1; d >= 0; d--) {
    const v = trace[d];
    const at = (k) => v[k + d + 1];
    const k = x - y;
    const prevK = k === -d || (k !== d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
    const prevX = at(prevK);
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) ops.push({ type: "same", a: --x, b: --y });
    if (d > 0) {
      if (x === prevX) ops.push({ type: "add", b: --y });
      else ops.push({ type: "del", a: --x });
    }
  }
  return ops.reverse();
}

/**
 * Rows for display: changed lines with `context` unchanged lines around them.
 * Each row: {key, type: same|add|del|gap, oldLine, newLine, text}.
 */
export function lineDiff(before, after, context = 3) {
  const a = before == null ? [] : String(before).replace(/\r\n/g, "\n").split("\n");
  const b = after == null ? [] : String(after).replace(/\r\n/g, "\n").split("\n");
  // Trim the shared start and end first; Myers then only sees the changed middle.
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length,
    endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--;
    endB--;
  }
  const middle = myers(a.slice(start, endA), b.slice(start, endB));
  const ops = [];
  for (let i = 0; i < start; i++) ops.push({ type: "same", a: i, b: i });
  for (const op of middle)
    ops.push({ type: op.type, a: op.a === undefined ? undefined : op.a + start, b: op.b === undefined ? undefined : op.b + start });
  for (let i = 0; i < a.length - endA; i++) ops.push({ type: "same", a: endA + i, b: endB + i });

  const keep = new Array(ops.length).fill(false);
  ops.forEach((op, i) => {
    if (op.type === "same") return;
    for (let j = Math.max(0, i - context); j <= Math.min(ops.length - 1, i + context); j++) keep[j] = true;
  });
  const rows = [];
  let added = 0,
    removed = 0;
  ops.forEach((op, i) => {
    if (op.type === "add") added++;
    if (op.type === "del") removed++;
    if (!keep[i]) {
      if (rows.length && rows[rows.length - 1].type === "gap") rows[rows.length - 1].count++;
      else rows.push({ key: "g" + i, type: "gap", count: 1, text: "" });
      return;
    }
    rows.push({
      key: "r" + i,
      type: op.type,
      oldLine: op.a === undefined ? "" : op.a + 1,
      newLine: op.b === undefined ? "" : op.b + 1,
      text: op.type === "add" ? b[op.b] : a[op.a],
    });
  });
  for (const row of rows) if (row.type === "gap") row.text = `… ${row.count} unchanged line${row.count === 1 ? "" : "s"} …`;
  return { rows, added, removed };
}
