# Inventory Allocation Simulator — Coding Standards: AI Discipline

> Split from `CODING_STANDARDS.md` during Klevar sync to keep bounded rules files under 10K characters. This file is core and is listed in `.agent/rules/_index.md`.

## AI Discipline Rules (Prevent Common AI Failures)

### No Scope Creep
- **ONLY implement what's asked or what's next in `docs/progress.md`.** Do not add features, helpers, utilities, or "nice-to-haves" that aren't in the spec.
- If you think something SHOULD be added, ASK the user first. Never add it silently.

### No Phantom Dependencies
- **NEVER import a package that isn't in the dependency file** (requirements.txt / package.json / etc). Add it FIRST, then use it.
- Before using any library method, **verify it exists** in that version. Don't hallucinate API methods.

### No Placeholder Code
- **NEVER write `# TODO`, `pass`, `...`, or `NotImplementedError`** as final code. Every function must be fully implemented before marking the task done.

### No Hallucinated APIs
- Before calling any external library method, **verify the method exists** by checking docs or the installed package.
- If unsure, say so and check rather than assuming.

### No Silent Failures
- **NEVER write code that swallows errors silently.** Every `except`/`catch` block must either re-raise, log, or return a meaningful error.
- `except: pass` / `catch {}` is permanently BANNED.

### No Silent Workarounds (CRITICAL — Prevents Hidden Schema/Spec Gaps)
- **NEVER hardcode a value that should come from config, schema, or API response** to "make the test pass."
- Template token fails to resolve? Schema field missing? Context API missing data? **STOP.** Either (1) extend the schema in this batch if PRD already specifies the field, or (2) escalate as `SILENT_WORKAROUND` and wait for user decision.
- Banned pattern: literal tenant/customer identity strings (names, addresses, emails, registrations, legal boilerplate, wordmarks) written into templates, emails, invoices, legal docs, or any config-driven surface. Single-tenant fixtures mask this — it leaks in production.
- **Also banned:** silently compacting/shrinking/truncating a file to hit a size limit (dropping bullets from a rules file, collapsing entries in a catalog, removing rows from a table to fit under 10K). The fix for an oversized knowledge file is the directory-per-kind pattern below, not truncation.
- Applies manual + `/implement-next` + `/yolo`. See `yolo-honesty-checks.md` §8 for the full trigger table, rejected-pattern examples, and Option A/B/C routing.

### Append-Only Knowledge Files Banned (CRITICAL — Prevents Recurring Splits)
- **NEVER create or grow a single file that accumulates entries of unbounded cardinality.** New gotcha → new file. New pattern → new file. New module → new file. New foundation primitive → new file. New build-journal batch → new file.
- Canonical directory-per-kind locations:
  - `.agent/knowledge/patterns/` — one file per pattern (filename `NNN-slug.md`)
  - `.agent/knowledge/gotchas/` — one file per gotcha (filename `YYYY-MM-DD-slug.md`)
  - `.agent/knowledge/modules/` — one file per module (filename mirrors source path)
  - `.agent/knowledge/foundation/` — one file per foundation primitive (filename `category-slug.md`)
  - `.agent/knowledge/checks/` — one file per project-local enforcement check (filename `{failure_type}-{slug}.md`, lowercase hyphenated). Written by `yolo-subagent-reinforce` after recurring failures; read by implement sub-agent's Step 4 plan-validation; retire-able via `/audit-reinforcements`.
  - `docs/build-journal/` — one file per batch (filename `NNN-batch.md`)
- Each directory has an `_index.md` catalog that the AI rewrites when siblings are added, renamed, or removed. The index is a catalog, not a growing file — it tracks directory membership, nothing more.
- **Exempt from this rule** (bounded cardinality, safe as single files): `CODING_STANDARDS*.md` (fixed taxonomy of rule categories), workflow stubs, `CODEBASE_CONTEXT.md` tech-stack / commands / env-vars tables, PRD sections.
- **When unsure whether cardinality is bounded:** assume unbounded and use a directory. A project with 3 patterns today has 30 in a year; one file per pattern scales, one row per pattern in a table does not.
- Violations show up as recurring "split this file" work every few batches. The split is firefighting — the fire is the append-only architecture. See `MAINTAINING.md` — "Append-Only Knowledge Files Banned" for migration guidance.

### No Over-Engineering
- Match the spec's complexity level. No abstractions without 2+ concrete implementations.
- Build for the scale defined in the spec, not 100x that.

### Verify Before Claiming
- **NEVER say "done" or "all tests pass" without actually running the tests** and showing the output.
- **NEVER say "this follows the spec" without having read the relevant section** in this session.
- If you haven't read a file in this conversation, you don't know what's in it. Read it first.

### Hardcoded Secrets Banned (CRITICAL)
NEVER write real API keys, tokens, passwords, JWTs, or signing secrets as string literals in any tracked file (including `.yolo/`). Read from env or vault. Pre-commit scanner: `scripts/scan-secrets.ps1`. Full rule + pattern catalogue + recovery flow → `CODING_STANDARDS_DOMAIN.md` § Secrets Management. YOLO-specific routing → `yolo-honesty-checks.md` Section 11.

### Respect .gitignore (CRITICAL — Prevents Accidental Exposure)
- **NEVER run `git add -f` on ANY file.** If a file is gitignored, it is gitignored ON PURPOSE.
- `docs/progress.md`, `docs/build-journal/`, `docs/architect_journal.md`, `.agent/workflows/`, `.agent/guides/`, `.agent/agents/`, `.agent/.last-sync`, `.yolo/`, `.claude/`, and PRD files are LOCAL working files (tracked during dev via the `⚠️ TRACKED DURING DEV` pattern, stripped by `/prepare-public`). They must NEVER end up in a public release.
- **Proprietary files are tracked during development** so all platforms can reference them. `.gitignore` has commented-out entries marked `⚠️ TRACKED DURING DEV` — this is the default. Run `/prepare-public` before making the repo public.
- If `git status` doesn't show a file as staged after `git add .`, that means `.gitignore` is working correctly. **Do not "fix" it.**
- The ONLY acceptable staging command is `git add .` (which respects `.gitignore`).

### Full Read Rule (CRITICAL — Prevents Context Loss)
- **When ANY workflow instructs you to "read" a file, you MUST read the ENTIRE file from first line to last line.**
- If the file is longer than your read limit, make multiple sequential read calls (e.g., lines 1–200, 201–400, 401–end) until **every line has been read.**
- Do NOT read a partial subset and assume you understand the rest. Critical rules, patterns, and constraints are often buried later in the file.
- This applies universally to: PRD, `progress.md`, `CODING_STANDARDS.md`, `CODEBASE_CONTEXT.md`, Shared Foundation files, source files referenced in tasks, and any other file a workflow tells you to read.

### Read Shared Foundation Before Coding (CRITICAL — Prevents Duplication)
- Before writing ANY new utility, helper, middleware, handler, component, or shared pattern, read every file listed in the **Shared Foundation** table in `CODEBASE_CONTEXT.md`.
- If a pattern, function, or module already exists there — **USE IT.** Do not recreate it.
- This applies to EVERY implementation task, regardless of which workflow triggered it.

### Workflow Discipline
- **Max 30 workflow files** in `.agent/workflows/`. If approaching 30, retire rarely-used workflows or convert procedural knowledge to reusable global skills.
- Before creating a new workflow, check if an existing one can be extended.

### Search Before Creating (CRITICAL — Prevents Duplicate Code)
- **Before creating ANY new file, function, class, or utility**, search the codebase first:
  1. Search file contents for the function/class name
  2. Search for the file by name
  3. Check relevant module exports / `__init__` files
- If it already exists, **USE IT**. Do not recreate it.
- If a similar function exists, **extend it** — don't create a parallel version.
- When in doubt, **ASK the user**: "I can't find X — does it exist, or should I create it?"
