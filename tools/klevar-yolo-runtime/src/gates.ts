import path from "node:path";
import { exists, writeText } from "./util/fs.js";
import type { Batch, GateResult } from "./types.js";

export async function writeRuntimeGates(cwd: string, batch: Batch, gates: GateResult[]): Promise<void> {
  const padded = String(batch.number).padStart(3, "0");
  for (const gate of gates) {
    await writeGate(cwd, gate.name, `batch-${padded}`, gate.passed ? "PASS" : "FAIL", batch.number, gate.flags);
  }
}

export async function writeGate(cwd: string, workflow: string, stem: string, result: string, batch: number, flags: string[] = []): Promise<void> {
  const body = [`workflow: ${workflow}`, `timestamp: ${new Date().toISOString()}`, `result: ${result}`, `batch: ${batch}`, `flags: ${flags.join(", ") || "none"}`, ""].join("\n");
  await writeText(path.join(cwd, `.yolo/gates/${workflow}-${stem}.md`), body);
}

export async function verifyPreviousBatchGates(cwd: string, batchNumber: number): Promise<string[]> {
  if (batchNumber <= 1) return [];
  const prev = String(batchNumber - 1).padStart(3, "0");
  const required = ["e2e", "journal", "closeout"];
  const missing = [];
  for (const gate of required) {
    const rel = `.yolo/gates/${gate}-batch-${prev}.md`;
    if (!(await exists(path.join(cwd, rel)))) missing.push(rel);
  }
  return missing;
}
