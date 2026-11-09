// Putting things on disk: a new text file, or a whole Courier e-mail (text + attachments) in a folder.
// These only add files, so they run without a confirm: nothing existing is overwritten (a taken name gets " (2)"),
// and only ordinary places in the home folder are allowed (not hidden folders, not ~/Library except iCloud/Google Drive).
import fs from "node:fs";
import { saveCourierEmail } from "./courier.js";
import path from "node:path";
import { expand } from "./actions.js";
import { prettyPath } from "./find.js";
import { HOME, ICLOUD, p } from "./paths.js";
import { appendLine } from "./store.js";

const AUDIT = p("audit.jsonl");
const CLOUD = path.join(HOME, "Library/CloudStorage");

/** The folder or file path, expanded, if Brain may add files there. */
function target(f) {
  const abs = expand(f);
  const rel = path.relative(HOME, abs);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) throw new Error(`only inside your home folder: ${f}`);
  const inDrive = abs.startsWith(ICLOUD + "/") || abs === ICLOUD || abs.startsWith(CLOUD + "/");
  if (!inDrive && (rel === "Library" || rel.startsWith("Library/"))) throw new Error(`not in ~/Library (except iCloud Drive / Google Drive): ${f}`);
  if (rel.split(path.sep).some((s) => s.startsWith("."))) throw new Error(`not in hidden folders: ${f}`);
  return abs;
}

const clean = (name) => String(name).replace(/[/:\\\u0000-\u001f]/g, "-").replace(/^\.+/, "").trim().slice(0, 180) || "bez nazvu";

/** A free name in dir: "name.ext", else "name (2).ext", ... */
function free(dir, name) {
  const ext = path.extname(name), base = name.slice(0, name.length - ext.length);
  for (let i = 1; ; i++) {
    const f = path.join(dir, i === 1 ? name : `${base} (${i})${ext}`);
    if (!fs.existsSync(f)) return f;
  }
}

function put(dir, name, data) {
  fs.mkdirSync(dir, { recursive: true });
  const f = free(dir, clean(name));
  fs.writeFileSync(f, data, { flag: "wx" });
  return f;
}

/** A new text file (Markdown, txt, csv, ...). */
export function writeFile({ path: f, text }) {
  const abs = target(f);
  const out = put(path.dirname(abs), path.basename(abs), text);
  appendLine(AUDIT, { write_file: out, chars: text.length });
  return { saved: prettyPath(out), path: out, chars: text.length, renamed: out !== abs ? "the name was taken, so a number was added" : undefined };
}

// ---- e-mail (Courier only) -----------------------------------------------------------------------------------------

/** A whole Courier e-mail conversation as a Markdown file, plus its attachments, in one folder. */
export async function saveEmail({ id, folder = "~/Downloads", attachments = true }) {
  const dir = target(folder);
  // Courier ids: "courier:123" (search_everywhere's courier_id) or the plain id from the courier tools
  const cid = String(id).replace(/^courier:/, "");
  const { md, files } = await saveCourierEmail({ id: cid, dir, put: (d, name, text) => put(d, name, text) });
  appendLine(AUDIT, { save_email: `courier:${cid}`, text: md, attachments: files.length });
  return { folder: prettyPath(dir), text: { name: path.basename(md), path: md }, attachments: attachments ? files : [] };
}
