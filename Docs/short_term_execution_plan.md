# Short-Term Execution Plan (WS-J)

## Target Lock
- Device model: `SM-G975F`
- Codename: `beyond2lte`
- SoC lane: Exynos only
- Snapdragon/QCOM artifacts, metadata, or assumptions are out of scope and denied.

## Stage A - Env and Artifact Bootstrap
Entry criteria:
- Repo scaffold exists with `Docs/`, `scripts/`, `artifacts/`, `fixtures/`.
- Operator has approved run identifier.

Execution:
- Establish deterministic artifact logging path.
- Enforce checksum manifest format and metadata parsing.

Exit criteria:
- Preflight script runs in strict simulation mode.
- Preflight script runs in off simulation mode with read-only adb checks.
- Artifact outputs produced for each run.

## Stage B - Identity, vbmeta, Rollback Gate
Entry criteria:
- Stage A complete.
- Device lane declared as `SM-G975F` / `beyond2lte` / Exynos.

Execution:
- Validate identity metadata and checksum manifest.
- Validate vbmeta/chain assumptions and rollback plan presence.
- Require rollback rehearsal evidence before flash eligibility.

Exit criteria:
- Fail-closed gate passes with no identity, checksum, or metadata mismatch.
- Rollback rehearsal evidence archived.

## Stage C - Headless-First Validation
Entry criteria:
- Stage B gate pass evidence available.
- Latest strict and off preflight runs both passed (`--simulate strict` and `--simulate off`).

Execution:
- Run non-destructive, headless checks first (boot path, core services, connectivity).
- Capture reproducible logs under `artifacts/`.

Exit criteria:
- Headless checks pass with stable evidence set.
- No destructive change required to maintain baseline.

## Stage D - Optional Desktop/Tooling Layer
Entry criteria:
- Stages A-C passed.

Execution:
- Add desktop/tooling experiments only as optional layer.
- Keep fallback to headless baseline at all times.

Exit criteria:
- Desktop/tooling status documented with known gaps and rollback path unchanged.

## Artifact Discipline and Evidence
- Each run stores timestamped logs under `artifacts/`.
- Manifest uses `sha256` lines in `HASH  file` format.
- Evidence bundle includes command line, manifest copy/reference, selected serial (off-mode), decision result, and exit code.

## Risk Register
- **vbmeta gate risk:** incorrect assumptions can soft-brick; mitigation is strict identity + chain checks and fail-closed logic.
- **Downstream kernel desktop gap risk:** desktop features may be incomplete; mitigation is Stage C headless-first baseline.
- **Rollback realism risk:** untested rollback is not accepted; mitigation is mandatory rehearsal evidence before flash eligibility.
