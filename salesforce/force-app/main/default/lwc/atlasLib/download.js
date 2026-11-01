// Lightning Web Security only creates Blobs of a few types, with no ";charset=" part.
const ALLOWED = new Set(["application/zip", "application/json", "application/pdf", "text/plain"]);

/** The Blob type Lightning allows: the plain type if listed, otherwise octet-stream (the file name still sets how it opens). */
export function blobType(mime) {
  const plain = String(mime || "").split(";")[0].trim().toLowerCase();
  return ALLOWED.has(plain) ? plain : "application/octet-stream";
}

/**
 * Saves text or bytes as a file. The link must be an <a> in the calling component's
 * own template; Lightning blocks clicks on links created outside it.
 */
export function downloadFile(link, name, data, mime) {
  const url = URL.createObjectURL(new Blob([data], { type: blobType(mime) }));
  link.href = url;
  link.download = name;
  link.click();
  link.removeAttribute("download");
  // eslint-disable-next-line @lwc/lwc/no-async-operation
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
