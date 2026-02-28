# WS-J Short-Term Scaffold

## Purpose
This repository is the short-term execution track for WS-J goals: safe, evidence-driven enablement work for postmarketOS + Kali on Samsung Galaxy S10+ Exynos.

## Scope
- Target lane: `SM-G975F` (`beyond2lte`), Exynos only.
- Build a fail-closed preflight and artifact discipline before any flash operations.
- Prioritize headless validation and rollback readiness over desktop polish.

## Non-Goals
- No Snapdragon or mixed-device support in this short-term track.
- No repartitioning, no destructive experimentation, no one-off manual shortcuts.
- No desktop-first assumptions before headless gates pass.

## Stage Model (A-D)
- Stage A: Environment and artifact bootstrap (repo scaffolding, manifest/checksum discipline, logging path).
- Stage B: Identity + vbmeta + rollback gate (target confirmation, signing chain checks, rollback rehearsal evidence).
- Stage C: Headless-first validation (boot/service/network checks with reproducible logs).
- Stage D: Optional desktop/tooling layer (only after A-C pass; desktop gaps treated as optional risk-managed work).

## Safety Constraints
- No repartitioning in this track.
- Fail closed on identity mismatch, manifest parse errors, or checksum mismatch.
- Rollback rehearsal evidence is required before controlled flash eligibility is documented.

## Testing Phase Entry Checklist
- Strict preflight passes: `bash scripts/run_preflight.sh ... --simulate strict` exits `0`.
- Off preflight passes: `bash scripts/run_preflight.sh ... --simulate off` exits `0` using read-only adb checks.
- Off preflight confirms one connected device, `adb get-state=device`, and expected identity tuple (`model/codename/SoC`).
- Preflight emits both a log and machine-readable evidence JSON, and supports run-scoped output via `PRECHECK_ARTIFACT_DIR`.
- No Snapdragon/QCOM indicators appear in target args, manifest metadata, or device hardware identity.

## Live Runner Profile
- Example profile: `profiles/live_s10_exynos.env.example`.
- Live wrapper: `bash scripts/run_preflight_live.sh --env-file profiles/live_s10_exynos.env.example`.
- Wrapper defaults `SIMULATE=off` when omitted and denies missing required fields.

## Artifact Pruning
- Use `bash scripts/prune_artifacts.sh` to enforce retention guardrails.
- Defaults: `--keep-days 14`, `--keep-count 200`, preserves `.gitkeep`.
- Safe preview: `bash scripts/prune_artifacts.sh --dry-run`.

## Reproducible Runner
- Execute `bash scripts/run_pipeline.sh` to run shell syntax checks and test suites in one reproducible step.
- Each run gets an isolated run directory: `artifacts/runs/<UTCSTAMP>_<rand>/`.
- On success, pipeline emits inside that run directory:
  - `pipeline_bundle_<UTCSTAMP>.json`
  - `pipeline_bundle_<UTCSTAMP>.sha256`
- Bundle references preflight evidence generated in the same run directory and signs only bundle + run-local evidence.
- Pipeline acquires a lockfile (flock when available, lock directory fallback), then auto-runs `scripts/prune_artifacts.sh` on success.
- Set `PIPELINE_SKIP_PRUNE=1` to skip the automatic prune step.

## Evidence Contract
- Evidence JSON and pipeline bundle JSON include `schema_version` and `tool_version`.
- Usage failures emit minimal FAIL evidence JSON with `failure_stage=usage` and preserve exit code semantics (`2/3/4/5`).

## What Is Still Missing Before Real Phone Flash
- A production image bundle for `SM-G975F`/`beyond2lte` Exynos (not fixture files), with manifest metadata and verified hashes.
- Finalized flash procedure for the real device lane (exact Heimdall/Odin command sequence, partition targets, and expected outputs).
- Verified bootloader/download-mode readiness on each test phone (OEM unlock state, unlock confirmation, USB transport stability).
- AVB/vbmeta and rollback plan evidence tied to the exact image build and device serials that will be flashed.
- Full backup + restore rehearsal evidence on representative hardware before first controlled flash attempt.
- A signed operator checklist/runbook for go/no-go execution (human approval token, owner, timestamp, rollback owner).

Current repository status: this repo provides fail-closed preflight and evidence discipline only; it does not yet execute hardware flash commands.

## Fedora Handoff Paths
- Candidate archive copied for office use: `images/kali_native_beyond2lte_20260224_143837.zip`.
- Extracted candidate artifacts: `images/unpacked/kali_native_beyond2lte/artifacts/`.
- Key extracted docs: `images/unpacked/kali_native_beyond2lte/docs/FLASH_STEPS.md` and `images/unpacked/kali_native_beyond2lte/docs/HANDOFF_CHECKLIST.md`.
- These are candidate inputs only; treat them as untrusted until identity, hash, and rollback gates pass in the preflight flow.
