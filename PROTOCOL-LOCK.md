# Pilot 004 — PROTOCOL-LOCK v3.0 (FROZEN)

**Name:** H100 Migration-Replication × Red-Dot Recipe Retry
**Status:** FROZEN 2026-10-10. §10 artifact hashes backfilled; the window starts at freeze.
**Parent documents:** Pilot 002 Protocol Lock v2.1 + PREREG-ADDENDUM-02~06 (Pilot 003). Anything not covered here inherits them unchanged.

---

## 0. Protagonist test (hard gate)

The optimization artifacts this pilot ships = **deliverable configurations on H100**: (1) a migration-replication stock-FP8 configuration (Pilot 002's result surviving on new hardware); (2) a retried exemption recipe (target: quality gate PASS + performance CI lower bound ≥ 1.50×). Measurement and the evidence chain are supporting cast. Effiq ships optimization outcomes; we publish measurement data to build a verifiable, re-runnable trust moat — the product is the optimization.

## 1. Relationship to existing verdicts (goalpost guard, frozen)

- Pilot 003's FAIL verdict on L40S is **permanently valid** — no retrial, no softening, no re-adjudication.
- Every claim in this pilot is hardware-scoped to **H100 SXM**, printed on the verdict title line.
- No external material may frame Pilot 004 numbers as overturning the Pilot 003 verdict; 004 is a new claim inside a new hardware boundary.

## 2. Dual objectives and verdict rule

### Objective 1 (migration replication)
- Comparison: Arm B (stock FP8, exact Pilot 002 stage-05 arm-B config) vs Arm A (BF16), H100-local.
- Verdict: paired-bootstrap 95% CI lower bound ≥ 1.20× → PASS (Protocol-Lock continuity line). The Pilot 002 2.33× figure is descriptive cross-hardware context only, never a verdict input.
- The quality side of the migration arm is recorded descriptively; it is not gated.

### Objective 2 (red-dot retry)
- Comparison: Arm C (stage-11 screening winner) vs Arm A.
- Dual gates (BOTH required):
  - Quality gate: §6 panel rule — worst judge, overall AND per-axis delta ≥ −0.1;
  - Performance gate: paired-bootstrap 95% CI lower bound ≥ **1.50×**; secondary gate: pooled P95 TPOT / TTFT non-inferiority (C/A ≤ 1.05).
- Continuity reporting (vs 1.20×) is published as usual but does not decide.
- **n = 10 formal runs; no straddle — n=10 is final.**
- The two primary comparisons are pre-registered and adjudicated independently; neither borrows interpretive license from the other.

### FAIL handling (pre-registered)
- Screening exhausted → publish the FAIL in full; the lever map's red zone deepens.
- Single-shot confirmation miss (quality gate) → publish the FAIL.
- Quality green, performance missed → publish the FAIL + trigger the double-FAIL review (output = cause-of-death analysis + three options: fix the cause and retry / keep the flag on another track / honorable burial; the review's object is whether the current lever library can ship on the commercial line, not company survival).
- Evidence contamination (hash mismatch / non-zero leak scan) → the batch is voided and disclosed as such.

## 3. L1 model and engine boundary

- Qwen/Qwen2.5-14B-Instruct @ `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8` (unchanged).
- vLLM 0.31.0 (pinned); builder llmcompressor 0.12.0 + compressed-tensors 0.17.0 + transformers 5.10.4 (Pilot 003 terminal golden stack); full `pip freeze` archived as the environment anchor.
- Hardware: single H100 SXM 80GB; prefix caching OFF; max_model_len 32768. Any change = a new pilot.
- An A100 negative anchor is an optional add-on run (no FP8 hardware, negative result expected), separately approved and independently disclosed; it does not affect this protocol's verdict.
- **Model-coverage gap declaration (review addendum):** locking the evidence chain to Qwen2.5-14B is deliberate (one variable at a time — hardware only — preserving cross-pilot comparability); the coverage gap on mainstream production model families (DeepSeek/Qwen3-class) is scheduled for closure in the 005 pipeline stage; stage-10's 0.5B dry-run mechanism doubles as the model-portability test bench.

## 4. L2 workload and operating point

- Azure LLM Inference Trace 2024 anchor chain inherited (conv `a0cc9b96…3941` / code `71de5c55…448f`); slice plans inherited from the Pilot 002 stage-01 manifest (merged_sha chain `0c0fcf14…` and six further pairs), TRACE_SEED=20261010 unchanged.
- Operating point = re-calibration on H100 (stage-10 embeds the Pilot 002 stage-02 rule verbatim: descending grid scan, ≥95% SLO compliance defined as TTFT≤5s AND TPOT≤100ms, all-grid-fail fallback clause with disclosure string). **Calibration slices are watermarked and never enter any CI.**
- FILLER_SEED=20261010 inherited; the workload disclosure doctrine is unchanged (declared synthetic filler, shaped to trace token counts).

## 5. L3 arm set and screening

- Formal measurement arms: A (BF16) / B (stock FP8) / C (screening winner). Anchor arm a4-exempt-attn rebuilt as-is on H100 (recipe `5065e67e…df8`) — descriptive longitudinal comparison only, never in a verdict.
- Screening candidate arms ≤4 (finalized 2026-10-10 after commercial-goal review):
  - b1 = **profile-driven minimal exemption** (primary hypothesis H1): per-module sensitivity profile → exempt only the few attention projections with outlier error, FP8 everywhere else;
  - b2 = **activation smoothing + profile-driven minimal exemption** (driven by Pilot 003 screening evidence: a2-smooth narrowed the clarity wound from −0.250 to −0.075 while keeping full-FP8 throughput — quality back at the line, speed untouched; the most commercially shaped lever);
  - b3 = a4 + KV-cache FP8 (H2: attacks the saturation-slice escape cost exposed by Pilot 003 run-3);
  - seat 4 = the wave-2 deterministic merge rule (as in 003: merge(top1, top2), tie-break overall delta, then arm_id).
- **Retry dual-side risk declaration (review addendum):** a4's clarity margin under the red-dot judge was only 0.133 (+0.033 vs the −0.1 line) — narrowing the exemption granularity necessarily gives back part of the quality gain; b1/b2 carry a real quality-gate risk. Screening is the outpost; a missed single-shot confirmation is a legitimate, publishable FAIL.
- **Sensitivity profiling method frozen (H1's legitimacy source):** the 256-text calibration set is inherited (`f7020a78…c8ab8`); the per-module quantization error metric is per-module output MSE; the exemption-subset selection rule is a deterministic function (top-k + error threshold). The method is public in this protocol; k and the threshold are recipe parameters, gate-layer, pod-only.
- Screening discipline inherits 003: the 40-item screening set is reused (`d0b3da96…9b5ab`, reuse disclosed); the cheap-judge probe order is unchanged; the winner needs clarity ≥ −0.05 to advance; **single-shot confirmation — a miss is a published FAIL**.

## 6. L5 quality gate (confirmation phase, full 003 craft)

- The frozen 150-item set (`728b2f83…5cf7d`) and the same blind map (`684aea8d…`) are inherited; **gen_A is regenerated H100-locally** as the within-hardware reference (fair comparison on one hardware).
- Panel: seat 1 mandatory = deepseek-chat-v3-0324 (the original red-dot judge); the other two seats follow the frozen probe order (glm-4.6 → v3.1-terminus → chat-v3.1); **≥2 vendor families or REFUSED**; the reasoning-parameter craft per ADDENDUM-06 (`enabled:false`) is the default; worst-judge rule; the judging prompt is byte-identical to 001/002/003.
- If every judge on the frozen list is unreachable on execution day, or the family clause cannot be satisfied → REFUSED; an owner decision is required and logged; no improvised substitutions.

## 7. L4 measurement design

- 10 runs × 3-arm blocked crossing (one block each of A/B/C per run; odd/even mirror-alternated lead-off); per-request TTFT/TPOT/E2E; run-seed base = **20265000** (distinct from the 002/003 segments).
- Paired statistics per the sealed doctrine: within-run pairing by request_id, log-ratio → run-level means → paired bootstrap (seed 20262002, 100,000 resamples).
- Run guardrails inherit the 003 craft: a 5xx voids the arm block with exit 45 and identical-load replay; client retries ConnectError only, ≤3; every request gets a row; anti-p-hacking = the measurement scripts physically contain no CI/P95 code — those live only in the sealed verdict script; pilot-logs is pushed after every completed run.

- vLLM batching under concurrency is not token-deterministic → the quality gate uses blind text comparison only (principle pre-registered in 002, inherited).

## 8. Window, checkpoints, and budget governance

- Window: 30 days from the freeze date; Day-7 checkpoint = dry-run full chain (0.5B) all green + golden environment anchor landed + H100 calibration complete; no dual-objective verdict by Day-30 → K9 review.
- Budget governance: owner-approved as the project requires; the AI ledger reports burn at fixed increments for calibration; **the public protocol carries no cost figures** — judge budgets are enforced as token caps (rule of 2026-10-10).

## 9. L7 publication obligations

- Within 7 days of the verdict: publish VERDICT.md + REPRODUCE.md; a FAIL is published in full, identically.
- The public repo effiq/pilot004 is built starting on the freeze date; logs keep flowing to pilot-logs (automatic push via tonight.sh, landing from 004).
- Public artifacts carry no cost figures; lever-category labels and recipe sha256 are public; recipe bodies are gate-layer, pod-only (three-layer disclosure policy unchanged).

## 10. Frozen artifacts (hash record)

| Artifact | sha256 |
|---|---|
| stages/10-preflight-calib.sh | `ad6710ae886c89f178de716690f9ae3259330ae90b07fecd79a8ad92265da031` |
| stages/11-arm-screening.sh | `171dd0ce6d50837bdd443c4fe4decca007989ca07aa0d0c9c8508bb39c40594e` |
| stages/12-red-dot-confirm.sh | `559c1faf72420e06b777038e3663747dfe4fbe2f09968feea098dfbe0f88f111` |
| stages/13-tuned-perf.sh | `7e1cdd9018868b7ad9605fcc67ad4c3cc459d1e402bf13e18d759bd076643625` |
| tonight.sh (pilot004) | `979ac788a65dc22b1351c421b47e760cb6008ae07988a6f3bd6246be5c4bea72` |
| arms-manifest.json (pilot004) | `4eccbcb324b67282d07aaa4f535d8a2a1a8663e3774509b57e6aa4ddfd445362` |

Backfilled 2026-10-10 after the four scripts + tonight.sh passed the eight-gate engineering review and a full sandbox stub chain. Any byte change to a frozen artifact after this date is a deviation and requires an addendum.

## 11. Execution commitments (004 tooling list, part of the frozen text)

Automatic pilot-logs push + leak scan; credential-embedded clone; built-in dry-run switch runs the full chain on 0.5B first; golden environment anchors (pip freeze + pinned templates); nvidia-smi before any package install; standard nohup launch; .gitignore collects runtime debris; the pod-rebuild checklist enumerates every local working file; verify-path environment dependencies are written into REPRODUCE with zero guessing; public figures reconcile with a units/definition column; AI-delivered code passes the eight-gate quality review with the gate record attached.

## 12. Predictions (subjective calibration, for reconciliation only — not criteria)

- Migration objective PASS: ~70% (H100 hardware tailwind is directionally favorable, but the change in saturation shape is an open question).
- Retry dual-gate PASS: ~45–55% (main winning path = fine-grained exemption recovering the light-tier 0.17 log points + n=10 narrowing the interval + H100 heavy-load shape; uncertainty concentrated in the intersection of the three).

---

*Frozen 2026-10-10. Deviations require a pre-registered addendum before execution.*
