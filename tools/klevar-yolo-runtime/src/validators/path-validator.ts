import type { GateResult, RuntimeConfig } from "../types.js";

export function validatePaths(files: string[], config: RuntimeConfig): GateResult {
  const flags = [];
  for (const file of files) {
    const explicitlyAllowed = matchesAny(file, config.policy.allowedGeneratedPaths);
    if (!explicitlyAllowed && matchesAny(file, config.policy.blockedPaths)) flags.push(`BLOCKED_PATH:${file}`);
    if (!explicitlyAllowed && matchesAny(file, config.policy.protectedPaths)) flags.push(`PROTECTED_PATH:${file}`);
  }
  return { name: "paths", passed: flags.length === 0, flags };
}

function matchesAny(file: string, patterns: string[]): boolean {
  return patterns.some((pattern) => matches(file, pattern));
}

function matches(file: string, pattern: string): boolean {
  if (pattern.endsWith("/")) return file.startsWith(pattern);
  if (pattern.includes("*")) return new RegExp(`^${globToRegex(pattern)}$`).test(file);
  return file === pattern || file.startsWith(`${pattern}/`);
}

function globToRegex(pattern: string): string {
  return pattern.split("*").map(escapeRegex).join(".*");
}

function escapeRegex(value: string): string {
  return value.replace(/[\\^$+?.()|{}[\]]/g, "\\$&");
}
