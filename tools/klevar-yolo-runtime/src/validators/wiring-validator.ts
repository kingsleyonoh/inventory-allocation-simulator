import { exists } from "../util/fs.js";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import type { Batch, BatchResult, GateResult } from "../types.js";

const VERIFIER_EXTENSIONS = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "kts", "cs", "rb", "php", "scala", "clj", "cljs", "swift", "m", "mm", "cpp", "cc", "cxx", "c", "h", "hpp", "md", "sh", "ps1"];
const VERIFIER_PATH = new RegExp(`[A-Za-z0-9_.\\/-]+\\.(?:test|spec|${VERIFIER_EXTENSIONS.slice().sort((a, b) => b.length - a.length).map(escapeRegex).join("|")})`, "gi");

export async function validateWiring(cwd: string, batch: Batch, result: BatchResult, required: boolean): Promise<GateResult> {
  if (!required) return { name: "wiring", passed: true, flags: [] };
  const requiresEntrypoint = batch.items.some((item) => ["[API]", "[UI]", "[JOB]", "[INTEGRATION]"].includes(item.tag));
  if (!requiresEntrypoint) return { name: "wiring", passed: true, flags: [] };
  const flags = [];
  if (!result.wiring?.required) flags.push("MISSING_WIRING_DECLARATION");
  if (!result.wiring?.entrypoints?.length) flags.push("NO_REACHABLE_ENTRYPOINTS");
  for (const entry of result.wiring?.entrypoints ?? []) {
    const verifiedBy = entry.verifiedBy || inferVerifierEvidence(cwd, entry.path);
    if (!verifiedBy) {
      flags.push(`ENTRYPOINT_UNVERIFIED:${entry.path}`);
      continue;
    }
    for (const verifier of extractVerifierFiles(verifiedBy)) {
      if (!(await verifierExists(cwd, verifier))) flags.push(`WIRING_VERIFIER_FILE_MISSING:${verifier}`);
    }
  }
  return { name: "wiring", passed: flags.length === 0, flags };
}

export function extractVerifierFiles(value: string): string[] {
  const matches = value.match(VERIFIER_PATH) ?? [];
  return [...new Set(matches.map((match) => match.replace(/^[\'"`(]+|[\'"`),.;:]+$/g, "")).filter((match) => /[\\/]/.test(match)))];
}

async function verifierExists(cwd: string, verifier: string): Promise<boolean> {
  if (await exists(`${cwd}/${verifier}`)) return true;
  for (const candidate of verifierExtensionCandidates(verifier)) if (await exists(`${cwd}/${candidate}`)) return true;
  return false;
}

function inferVerifierEvidence(cwd: string, entrypoint: string): string {
  const needles = verifierNeedles(entrypoint);
  if (!needles.length) return "";
  const matches: string[] = [];
  for (const file of collectVerifierCandidates(cwd)) {
    let text = "";
    try {
      text = readFileSync(join(cwd, file), "utf8");
    } catch {
      continue;
    }
    if (needles.some((needle) => typeof needle === "string" ? text.includes(needle) : needle.test(text))) matches.push(file);
    if (matches.length >= 3) break;
  }
  return matches.join(", ");
}

function verifierNeedles(entrypoint: string): Array<string | RegExp> {
  const value = entrypoint.trim();
  const withoutMethod = value.replace(/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+/i, "");
  const needles: Array<string | RegExp> = [];
  if (withoutMethod.startsWith("/")) {
    needles.push(withoutMethod);
    if (withoutMethod.includes(":")) needles.push(new RegExp(escapeRegex(withoutMethod).replace(/:[A-Za-z0-9_]+/g, "[^/'\"`]+")));
  }
  const normalized = withoutMethod.replace(/\\/g, "/");
  if (/\.[A-Za-z0-9]+$/.test(normalized)) {
    needles.push(normalized);
    needles.push(normalized.replace(/^src\//, "").replace(/\.[A-Za-z0-9]+$/, ""));
    needles.push((normalized.split("/").pop() ?? normalized).replace(/\.[A-Za-z0-9]+$/, ""));
  }
  const seen = new Set<string>();
  return needles.filter((needle) => {
    const key = typeof needle === "string" ? `s:${needle}` : `r:${needle.source}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function collectVerifierCandidates(cwd: string): string[] {
  const roots = ["tests", "test", "spec", "src"];
  const files: string[] = [];
  for (const root of roots) collectFiles(cwd, root, files);
  return files.filter((file) => /(?:test|spec|__tests__|tests[\/])|src[\/]/i.test(file));
}

function collectFiles(cwd: string, relDir: string, files: string[]): void {
  const dir = join(cwd, relDir);
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
      const full = join(dir, entry.name);
      const rel = relative(cwd, full).replace(/\\/g, "/");
      if (entry.isDirectory()) collectFiles(cwd, rel, files);
      else if (entry.isFile() && isVerifierSourceFile(rel) && statSync(full).size <= 250_000) files.push(rel);
      if (files.length >= 500) return;
    }
  } catch {
    // Missing verifier roots are common in small projects.
  }
}

function isVerifierSourceFile(file: string): boolean {
  return new RegExp(`\\.(?:${VERIFIER_EXTENSIONS.map(escapeRegex).join("|")})$`, "i").test(file);
}

function verifierExtensionCandidates(verifier: string): string[] {
  const normalized = verifier.replace(/\\/g, "/");
  const match = /^(.*)\.([A-Za-z0-9]+)$/.exec(normalized);
  if (!match || !isTestLikePath(normalized)) return [];
  const [, base, ext] = match;
  return VERIFIER_EXTENSIONS.filter((candidate) => candidate !== ext).map((candidate) => `${base}.${candidate}`);
}

function isTestLikePath(file: string): boolean {
  const name = file.split("/").pop() ?? file;
  return /(?:^|[._-])(test|spec)(?:[._-]|$)/i.test(name) || /(?:Test|Spec)\.[A-Za-z0-9]+$/.test(name) || /_test\.[A-Za-z0-9]+$/i.test(name);
}

function escapeRegex(value: string): string {
  return value.replace(/[\\^$*+?.()|{}[\]]/g, "\\$&");
}
