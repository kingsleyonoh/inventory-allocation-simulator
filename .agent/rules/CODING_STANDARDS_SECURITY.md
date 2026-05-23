# Inventory Allocation Simulator — Coding Standards: Security

> Split from `CODING_STANDARDS_DOMAIN.md` during Klevar sync to keep bounded rules files under 10K characters. This file is core and is listed in `.agent/rules/_index.md`.

## Security Rules

### Secrets Management (Hardcoded Secrets Banned — CRITICAL)
- **NEVER hardcode** real API keys, tokens, passwords, JWTs, OAuth secrets, signing keys, DB passwords, or webhook secrets as string literals in ANY tracked file. This includes `.yolo/`, `docs/`, `scripts/`, `tests/`, `fixtures/`, `migrations/`, and deployment configs.
- ⛔ **`.yolo/`, `docs/build-journal/`, `docs/yolo-inbox.md` are TRACKED DURING DEV** (`.gitignore` `⚠️ TRACKED DURING DEV` banner). Files there commit to git history on every YOLO push. Treat them as if they were in `src/` for secret-handling.
- **Required pattern:** read from env (`os.environ['X']`, `process.env.X`, `${VAR}`, `getenv('X')`) or vault. Document the env var in `.env.example` with a placeholder like `your-key-here`. **docker-compose.prod.yml is git-tracked** — use `${VAR}` references, NEVER inline passwords. Create `.env` on the server for secrets.
- **`.env` files** stay LOCAL and gitignored (`.env.local`, `.env.production`). Only `.env.example` is committed.
- Use environment variables in production (Railway / Vercel / Fly / GitHub Actions secrets / etc.).
- **Pre-commit scanner:** `scripts/scan-secrets.ps1` (PowerShell) and `scripts/scan-secrets.sh` (Bash) ship in every project. Manual audit: `pwsh scripts/scan-secrets.ps1 -Mode tracked` (full repo) or `-Mode staged` (staged-only). Exit 0 = clean, exit 1 = matches found (JSON report on stdout).
- **Detection patterns** (canonical source — `scripts/scan-secrets.ps1`): JWT-shape (`eyJ...`); provider prefixes (`sk_live_`, `sk_test_`, `pk_live_`, `pk_test_`, `sk-` for OpenAI, `sk-ant-` for Anthropic, `ghp_` / `gho_` / `github_pat_` for GitHub, `xoxb-` / `xoxp-` for Slack, `glpat-` for GitLab, `AKIA` / `ASIA` for AWS, `AIza` for Google); 32+ char hex / 40+ char base64 / 30+ char alphanumeric strings adjacent to `api_key` / `secret` / `token` / `password` / `auth` / `client_secret` keywords; database URLs with embedded credentials.
- **Allow-listed placeholders** (scanner permits): `${VAR}`, `${{VAR}}`, `{{TOKEN}}`, `<REDACTED>`, `<your-api-key>`, `your-key-here`, `example_key`, `sample_token`, `placeholder`, `redacted`, `fake_key`, `dummy_key`; ellipsis-truncated values (`eyJ...truncated`); lines containing `os.environ` / `process.env` / `getenv(` / `config.get(`.
- **YOLO enforcement layers** (see `yolo-honesty-checks.md` Section 11 for full table): (1) implement sub-agent's Step 4 plan-text scan → `HARDCODED_SECRET_INTENT`; (2) Step 10 staged-files scan pre-push → `HARDCODED_SECRET_DETECTED`; (3) master Phase 4.3a uncommitted-files scan → `CLOSEOUT_SECRET_DETECTED`. All three escalate immediately (no auto-retry — secret leakage requires human-driven rotation).
- **`/prepare-public` Step 0** runs the scanner over every tracked file before public release. Last line of defense.
- **Rejected justifications** (always invalid — see Section 11 for the full catalogue): "it's a dev key", "it's a one-shot script", "I'll scrub before pushing", "lint-staged catches it", "`.yolo/` is private", "tests need a real value", "I'll fix it next batch".
- **If a secret leaks:** rotate the credential at the issuer FIRST (assume compromised — it's in shell history, agent memory, system snapshots), update `.env` / vault SECOND, replace the literal with an env-var read THIRD, `git filter-repo --invert-paths --path <file>` to remove from history FOURTH, force-push LAST. Scrubbing alone does NOT remove the secret from history.
- **Never bypass.** No `git commit --no-verify` to skip the scanner. No deleting the scanner invocation from the workflow. No committing with the secret to "fix later". A secret that ships to git history once is compromised forever.

### Input Validation
- Validate ALL user input at the boundary (API route, form handler)
- Use framework validators (Pydantic, Zod, Django Forms)
- Never trust client-side validation alone

### Authentication & Authorization
- Verify auth on EVERY protected endpoint
- Check permissions, not just authentication
- Log auth failures

### SQL & Data Safety
- Use parameterized queries or ORM methods — NEVER string concatenation for SQL
- Sanitize HTML output to prevent XSS
- Validate file upload types and sizes

### Multi-Tenant Config-Driven Surfaces (CRITICAL — Prevents Cross-Tenant Leakage)

If PRD §2 mandates `tenant_id`, these surfaces MUST NEVER contain hardcoded per-tenant literals: document templates (invoices, quotes, contracts, legal boilerplate), transactional emails, PDF/printable artifacts, admin UI copy naming "the operator", API responses echoing tenant identity.

**Banned:** legal entity names as HTML literals, registration/license/tax numbers as constants, addresses inlined into templates, contact email/phone as constants, logo/wordmark paths for one specific tenant, disclaimer text naming a specific regulator or entity.

**Required pattern — Template Context API:**

Every config-driven surface renders against an **immutable snapshot** captured at generation time (not a live lookup — re-renders MUST use the snapshot for legal/audit accuracy). Snapshot shape lives in PRD §5 (emitting module); backing columns in PRD §4 Tenant Identity Columns.

- Extend schema BEFORE writing the template. Never write a token whose backing field doesn't exist.
- Turn ON strict undefined handling: Handlebars `strict: true`, Jinja2 `StrictUndefined`, equivalent. Missing tokens MUST throw, not silently emit `""`.

**Test contract:**

- Template tests MUST load ≥2 tenants and assert Tenant A's render excludes any Tenant B literal. See `CODING_STANDARDS_TESTING_LOGIC.md` — Multi-Tenant Fixtures Mandatory.
- `validate-prd` and `security-audit` grep template directories for tenant literals. Matches = `TENANT_IDENTITY_LEAK`.

**If you hit a missing field:** apply "No Silent Workarounds" (`CODING_STANDARDS.md`). Escalate for schema extension. Do not hardcode.
