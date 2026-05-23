import type { BatchResult, GateResult, TestEvidence } from "../types.js";
import { markCommand } from "../telemetry.js";
import { execCommand } from "../util/process.js";

export async function validateCommandEvidence(cwd: string, result: BatchResult, telemetryCwd = cwd): Promise<GateResult> {
  const flags: string[] = [];
  const rerunTargets: Array<[string, TestEvidence | undefined]> = [
    ["green", result.tests?.green],
    ["regression", result.tests?.regression],
    ["e2e", result.tests?.e2e]
  ];
  for (const [phase, evidence] of rerunTargets) {
    if (!evidence?.command || !isRunnableCommand(evidence.command)) continue;
    if (isNaturalLanguageRecipe(evidence.command)) {
      flags.push(`COMMAND_RERUN_NON_RUNNABLE_RECIPE:${phase}:${evidence.command}`);
      continue;
    }
    if (isUnsafeForegroundServerCommand(evidence.command)) {
      flags.push(`COMMAND_RERUN_UNSAFE_FOREGROUND_SERVER:${phase}:${evidence.command}`);
      continue;
    }
    const started = Date.now();
    await markCommand(telemetryCwd, phase, evidence.command, "started");
    const run = await execCommand(evidence.command, cwd, 1000 * 60 * 20);
    const durationMs = Date.now() - started;
    await markCommand(telemetryCwd, phase, evidence.command, run.exitCode === 0 ? "passed" : "failed", durationMs);
    if (run.exitCode !== 0) flags.push(`COMMAND_RERUN_FAILED:${phase}:${evidence.command}:${summarizeFailure(run.stderr || run.stdout)}`);
  }
  return { name: "command-rerun", passed: flags.length === 0, flags };
}

function summarizeFailure(output: string): string {
  return output.replace(/\s+/g, " ").trim().slice(0, 220) || "no output";
}

function isRunnableCommand(command: string): boolean {
  const trimmed = command.trim();
  if (!trimmed || /^N\/A\b|^not applicable\b|^not run\b|^skipped\b/i.test(trimmed)) return false;
  if (/^bootRun\b/i.test(trimmed)) return false;
  if (/\bon\s+[A-Z_][A-Z0-9_]*=/.test(trimmed) && /,\s*(curl|rg|grep|test)\b/.test(trimmed)) return false;
  return true;
}

function isNaturalLanguageRecipe(command: string): boolean {
  const trimmed = command.trim();
  if (/^(?:seed|start|run|open|click|login|create|verify|then)\b/i.test(trimmed) && /\b(?:with|then|and|before|after)\b/i.test(trimmed) && /\b(?:npx|npm|pnpm|yarn|bun|curl|http|GET|POST|PORT=)\b/i.test(trimmed)) return true;
  if (/\bthen\s+(?:curl|GET|POST|run|start)\b/i.test(trimmed) && !/[;&|]|&&/.test(trimmed)) return true;
  return false;
}

function isUnsafeForegroundServerCommand(command: string): boolean {
  const normalized = command.replace(/\s+/g, " ").trim();
  if (!/(?:^|[;&|]\s*|\b)(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:dev|start:dev|dev:api|serve|preview)\b/i.test(normalized) && !/\b(?:vite|next|nuxt|tsx\s+watch|nodemon)\b/i.test(normalized)) return false;
  if (/\b(?:curl|wget|httpie|http|pwsh|powershell)\b/i.test(normalized) || /\bGET\s+\/|\bPOST\s+\//i.test(normalized)) {
    return !/(?:&\s*(?:curl|wget|httpie|http)\b|\bstart-server-and-test\b|\bwait-on\b|\bconcurrently\b|\btimeout\s+\d+)/i.test(normalized);
  }
  return false;
}
