import os from "node:os";
import path from "node:path";

export const HOME = os.homedir();
export const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
export const DATA = path.join(ROOT, "data");      // caches, logs, proposals (not in git)
export const NOTES = path.join(ROOT, "notes");    // what you told Brain, plain Markdown
export const CONFIG = path.join(ROOT, "brain.config.json");
export const ICLOUD = path.join(HOME, "Library/Mobile Documents/com~apple~CloudDocs");

export const p = (...parts) => path.join(DATA, ...parts);
