// Copy during the click, before permissions or disk work can outlive activation.
function copySelection(text, container, html) {
  let focused = document.activeElement;
  while (focused?.shadowRoot?.activeElement)
    focused = focused.shadowRoot.activeElement;
  const area = document.createElement("textarea");
  area.value = text;
  area.readOnly = true;
  area.style.cssText = "position:fixed;left:-10000px;top:0";
  let rich = false;
  const listener = (event) => {
    if (!event.clipboardData) return;
    event.clipboardData.setData("text/html", html);
    event.clipboardData.setData("text/plain", text);
    event.preventDefault();
    rich = true;
  };
  // An open native dialog makes everything outside it inert.
  container.appendChild(area);
  if (html !== undefined) document.addEventListener("copy", listener);
  try {
    area.focus();
    area.select();
    return document.execCommand("copy") && (html === undefined || rich);
  } catch {
    return false;
  } finally {
    document.removeEventListener("copy", listener);
    area.remove();
    focused?.focus?.({ preventScroll: true });
  }
}

export async function writeClipboardText(text, container = document.body) {
  if (copySelection(text, container)) return true;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export async function writeClipboardHTML(
  html,
  text,
  container = document.body,
) {
  if (copySelection(text, container, html)) return true;
  try {
    await navigator.clipboard.write([
      new ClipboardItem({
        "text/html": new Blob([html], { type: "text/html" }),
        "text/plain": new Blob([text], { type: "text/plain" }),
      }),
    ]);
    return true;
  } catch {
    return false;
  }
}
