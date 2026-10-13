# Pilot 004 — Final Verdict

**Verdict: PASS** — both pre-registered objectives, on new hardware, zero post-hoc changes.

**Claim.** On a single NVIDIA H100 SXM 80GB serving Qwen2.5-14B-Instruct (revision `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8`) under vLLM 0.31.0, on a workload anchored to the Azure LLM Inference Trace 2024 at an H100-calibrated operating point:

1. **Migration replication — PASS.** Stock FP8 dynamic quantization (Pilot 002's exact arm-B configuration) delivers **1.96×** the end-to-end throughput of the BF16 default — paired-bootstrap 95% CI **[1.654×, 2.370×]**, pre-registered pass threshold 1.20× on the lower bound.
2. **Red-dot retry — PASS.** A profile-driven minimal-exemption FP8 recipe (b1) delivers **1.92×** — 95% CI **[1.627×, 2.324×]** against the pre-registered 1.50× bar — with P95 TPOT/TTFT non-inferiority (ratios 0.302 / 0.314 vs tolerance 1.05) **and** a blind quality gate passed under a 3-judge panel that includes the original Pilot 003 red-dot judge (worst-judge overall delta +0.013, tolerance −0.1).

Pilot 003's FAIL verdict on L40S is **permanently valid** and is not retried here; every claim on this page is hardware-scoped to H100 SXM. Pilot 002's 2.33× figure (L40S) is cross-hardware context only and was never a verdict input.

Everything below is reproducible from the archived raw logs. See [REPRODUCE.md](REPRODUCE.md).

---

## 1. Scope — what this verdict does and does not say

| In scope (declared before measurement) | Out of scope (no claim made) |
|---|---|
| GPU: single NVIDIA H100 SXM 80GB (driver 570.211.01 + CUDA 13.0 user-space compatibility layer) | Other GPUs (incl. other H100 SKUs), multi-GPU |
| Model: Qwen/Qwen2.5-14B-Instruct @ `cf98f3b3…caa8` (pinned) | Other models (coverage closure scheduled in the 005 pipeline) |
| Engine: vLLM 0.31.0; builder llmcompressor 0.12.0 + compressed-tensors 0.17.0 + transformers 5.10.4 | Other engines/versions |
| Workload: Azure LLM Inference Trace 2024 anchored slices (six frozen slice pairs, sha-chained; pair_3 oversampled per the declared frozen run map), declared synthetic filler; prefix caching OFF; max_model_len 32768 | Real customer traces |
| Operating point: re-calibrated on H100 (grid descent per the Pilot 002 stage-02 rule) — concurrency 16, SLO = TTFT ≤ 5 s AND TPOT ≤ 100 ms, observed compliance 0.9735. Calibration slices are watermarked and never enter any CI | Overload behavior (controlled load is a design choice; frontier-shift experiments are roadmap work) |
| Metric: per-request (prompt+output tokens)/wall-second; pairing by request_id within run | — |

This verdict is a statement about **this workload on this hardware with these recipes** — acceleration claims should be measured, not assumed.

## 2. Governance — how this was kept honest

- **Protocol-Lock v3.0** frozen and published **2026-10-10, before any measurement**, including both objectives, both gate thresholds, the statistical method, and the FAIL-publication obligations.
- **Four addenda (A1–A4)**, each committed and hash-recorded **before any further execution**: A1/A3 fixed a fused-module granularity defect class in recipe construction (dry-run path, then runtime-composition path); A2 made the evidence push path atomic and added unpushed-state protection after a tooling incident (§8); A4 narrowed the pre-push leak scan to newly-added lines. None changed thresholds, arms, judging, or statistics.
- **Anti-p-hacking:** the measurement scripts physically contain no CI code. The confidence intervals lived sealed inside the stage-13 verdict script until all 10 COMPLETE markers existed. n=10, no straddle — the run map (six slice pairs; pair_3 repeated in runs 7 and 10) was declared in the frozen script header.
- **Deterministic statistics:** bootstrap seed 20262002, 100,000 resamples. Same logs → byte-identical verdict.
- **External trust domain:** the quality gate was scored by three third-party models via API — `deepseek/deepseek-chat-v3-0324` (mandatory seat: the original Pilot 003 red-dot judge), `z-ai/glm-4.6`, `deepseek/deepseek-v3.1-terminus` — blinded to arm identity by the blinding map inherited **by hash** from the sealed Pilot 002 archive. Worst-judge rule. Raw judge responses archived row by row.
- **Custody chain:** the winning recipe is pinned by sha256 from screening through confirmation to performance; the checkpoint built from it is byte-identical across all three stages (`e59cd029913c8b66…`).
- **Audit trail:** every artifact is hash-pinned; every stage script has a `--verify` entry that recomputes its verdict from the archived logs alone; evidence was pushed continuously to the public logs repository during the run.

## 3. Migration gate (B vs A) — PASS

n = 10 formal runs; per-request pairing within run; statistic = run-level mean log-ratio → paired bootstrap over runs.

- Paired requests per run: 459 / 794 / 1754 / 1209 / 1390 / 946 / 1754 / 459 / 794 / 1754
- Run-level mean log-ratios (B/A): +0.4077, +0.4338, +1.1077, +0.5065, +0.6672, +0.5166, +1.1119, +0.4013, +0.4544, +1.1054
- **Point estimate: 1.9567×; 95% CI [1.6540×, 2.3696×]** — lower bound 1.654 ≥ 1.20 → **PASS**
- Descriptive (non-gate): pooled P95 TPOT ratio B/A = 0.294; P95 TTFT ratio = 0.306.

Honest reading: the lift is strongly load-dependent. The full picture, computed from the published run-level log-ratios above (geometric mean within each slice pair):

| Trace slice pair (light → heavy) | Runs | Migration B/A | Retry C/A |
|---|---|---|---|
| pair_1 | 2 | 1.499× | 1.478× |
| pair_2 | 2 | 1.559× | 1.548× |
| pair_4 | 1 | 1.660× | 1.630× |
| pair_6 | 1 | 1.676× | 1.605× |
| pair_5 | 1 | 1.949× | 1.917× |
| pair_3 (heaviest, oversampled ×3 per the frozen run map) | 3 | **3.029×** | **2.968×** |

**Descriptive, not the verdict statistic.** The only citable figures remain the frozen paired-bootstrap results above (1.9567× and 1.9215× with their CIs), which weight the ten runs equally per the pre-registered design. The per-slice rows are arithmetic on already-published numbers, shown so the peak — ≈3× on the heaviest slice — and the floor — ≈1.5× on the lightest — are both on the record rather than either one being cherry-picked. This load dependence is exactly why the workload is trace-anchored and the operating point is calibrated and disclosed: the number is only meaningful with its load attached.

## 4. Retry gate (C vs A) — PASS

**Quality half** (stage 12, single-shot, archived): frozen 150-item set, H100-local BF16 reference, 450 blind judgments.

| Judge | overall Δ (C−A) | per-axis range | Gate |
|---|---|---|---|
| deepseek-chat-v3-0324 (**original red-dot judge**) | **+0.013** | −0.007 … +0.033 | PASS |
| glm-4.6 | +0.162 | +0.093 … +0.200 | PASS |
| deepseek-v3.1-terminus | +0.056 | −0.007 … +0.087 | PASS |

Worst-judge rule: all three must pass; worst overall +0.013 ≥ −0.1 → **PASS**. Note the honest margin: under the strictest judge — the same judge family that issued Pilot 003's red dot — the recipe cleared the bar by +0.013, not by a mile. The correct statement is "no measurable quality degradation beyond tolerance", not "better than BF16".

**Performance half** (stage 13):

- Run-level mean log-ratios (C/A): +0.3957, +0.4242, +1.0941, +0.4885, +0.6506, +0.4734, +1.0929, +0.3856, +0.4496, +1.0766
- **Point estimate: 1.9215×; 95% CI [1.6274×, 2.3242×]** — lower bound 1.627 ≥ 1.50 → **PASS**
- Secondary gate: P95 TPOT 346.82 ms → 104.70 ms (ratio 0.3019); P95 TTFT 1.838 s → 0.578 s (ratio 0.3143); tolerance ≤ 1.05 → **OK**
- Continuity vs 1.20×: PASS (reported, does not decide)

The descriptive pooled per-request ratio (≈3.7×, request-count-weighted) is **not** the verdict statistic; the frozen statistic weights runs equally — and it is the only citable figure. (The per-slice-pair breakdown of both gates is in §3; the retry gate shows the same load-dependent shape, ≈1.5× light to ≈3× heavy.)

## 5. How arm C was chosen (screening, stage 11)

Five arms, 40-item screening set, cheap-judge probe, pre-registered proceed rule. Deltas vs the H100 BF16 reference (clarity / overall):

| Arm | clarity | overall |
|---|---|---|
| b0-control (Pilot 002 arm-B config) | +0.450 | +0.617 |
| **b1-profile-exempt (winner)** | **+0.550** | **+0.508** |
| b2-smooth-exempt | +0.475 | +0.392 |
| b3-a4-kv | +0.525 | +0.300 |
| b4-w2 (deterministic merge of top-2) | −0.125 | −0.017 |

b1 = per-module sensitivity profiling (192 attention projections × 256 calibration texts) → exempt only the outlier projections (fused-module granularity), FP8 everywhere else. The wave-2 merge arm b4 landed **negative** — exemption sets do not compose naively; this null result is part of the lever map. Screening is a nomination, not proof: the winner's screening bootstrap CI crossed zero, which is precisely why the single-shot confirmation (stage 12) exists.

## 6. Descriptive anchor (never enters any CI)

a4-anchor (Pilot 003's recipe class, rebuilt as-is on H100): pair_1 1.3732×, pair_3 2.2560× vs A — longitudinal context only. Descriptively, b1 outperforms the older heavier-exemption recipe on the heavy slice (≈3× run-level vs 2.256×): fewer exemptions, more speed, and it is the one that passed the panel.

## 7. Hash manifest (short form)

| Artifact | sha256 (short) |
|---|---|
| Frozen evaluation set (150) | `728b2f83…5cf7d` |
| Blinding map (inherited from sealed Pilot 002 archive) | `684aea8d…6392` |
| gen_A (H100 BF16 reference) | `35f03bc0…ed1a` |
| gen_C (b1, confirmation) | `4e441d57…6427` |
| Judge raw responses (confirmation) | `8b656f01…f06a` |
| Winner recipe (b1) | `3c80a875…a687` |
| b1 checkpoint (identical across stages 11/12/13) | `e59cd029…4bd8` |
| a4-anchor recipe / checkpoint | `10117c9d…315d` / `539cee71…c420` |
| Trace slice plans pair_1…6 | `0c0fcf14…`, `831d4a8b…`, `f3ab8040…`, `8e9753f6…`, `5784d2d1…`, `4d2cdcae…` |
| Environment anchor (pip freeze) | `b92f88ff…31a3` |

Full hashes live in the run summaries in the logs repository and are recomputed by the `--verify` entries.

## 8. Operational incidents, disclosed

- A completed stage-10 evidence run was **wiped by a tooling defect** (a leak-scan false positive that blocked the commit, followed by an unconditional `git reset` on the next launch). The run was recovered **byte-identical** from the git object store, re-verified against recorded hashes, and the root causes were fixed and published as Addendum A2 before any further execution.
- The fused-module defect class struck twice (A1: dry-run recipe; A3: runtime-composed recipe). Both were caught by built-in checks (dry-run phase; server startup), both fixed via addenda committed before re-execution.
- The pod was stopped and rebuilt mid-pilot: the trace slice plans were restored byte-identical from the network-volume backup and re-verified against the frozen anchors; the environment was rebuilt from the archived pip-freeze anchor.
- The pre-push leak scan initially covered pre-rule historical files that were already public (A4). No new leak occurred; the scan now covers newly-added lines.

The measurement system is designed so that interruptions cannot silently change results: partial data never carries a COMPLETE marker, and the verdict scripts refuse incomplete inputs.

## 9. Recipe disclosure policy

Lever-category labels and recipe sha256 values are public; recipe bodies are gate-layer (three-layer disclosure policy, unchanged since Pilot 001). Every verdict number on this page is independently computable from the public archives **without** the recipe body — see [REPRODUCE.md](REPRODUCE.md). Checkpoints are deleted after use by design, with sha256 anchors recorded; anyone holding a recipe can rebuild and hash-compare.

---

*Pilot 004 ran under Effiq's published protocol-governance rules: pre-registered criteria, frozen workload anchors, sealed statistics, blind external judging under a worst-judge rule, hash-pinned artifacts, published addenda, and a 30-day stop-loss window that closed on day 3 with a confirmed victory. Pilot 003's FAIL remains on the record, unchanged and unsoftened — the map's red zones are what made this result cheap to find.*
