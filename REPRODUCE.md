# Reproduce the Pilot 004 verdict

Every number in [VERDICT.md](VERDICT.md) is recomputed from archived raw logs by scripts in this repository. No GPU is needed for verification (only the original measurement needed one), and no network beyond cloning the two repositories. Requirements: `python3` ≥ 3.10 with `numpy`.

## 1. Layout

Clone both repositories side by side so that `$HOME/effiq` looks like:

```
$HOME/effiq/pilot004      <- this repository (scripts + protocol)
$HOME/effiq/pilot-logs    <- the raw measurement archives
```

```bash
mkdir -p ~/effiq && cd ~/effiq
git clone https://github.com/effiq/pilot004.git
git clone https://github.com/effiq/pilot-logs.git
```

## 2. Performance verdict (stage 13 — the dual gates)

```bash
bash ~/effiq/pilot004/stages/13-tuned-perf.sh --verify \
  ~/effiq/pilot-logs/2026-10-13/13-tuned-perf/run_1
```

This recomputes the verdict from the archived per-block raw JSONL alone: per-request pairing, run-level mean log-ratios, paired bootstrap (seed 20262002, 100,000 resamples — fully deterministic), both gates, and the P95 secondary gate. It then byte-compares the recomputed verdict against the archived `verdict_t.txt` / `verdict_t.json` (declared provenance fields normalized). The output must contain:

```
point estimate: exp(mean) = 1.9567x
paired bootstrap 95% CI: exp([+0.5032, +0.8627]) = [1.6540, 2.3696]x
MIGRATION GATE: PASS
```

```
point estimate: exp(mean) = 1.9215x
paired bootstrap 95% CI: exp([+0.4870, +0.8434]) = [1.6274, 2.3242]x
primary (CI >= 1.5x): PASS
[secondary] P95 TPOT: A=346.82ms C=104.70ms ratio=0.3019  OK
[secondary] P95 TTFT: A=1.838s C=0.578s ratio=0.3143  OK
RETRY GATE: PASS
```

```
PILOT 004 VERDICT: PASS
```

plus `VERIFY: ALL CHECKS PASSED`, and the 30 input-integrity lines (10 runs × 3 arms) each printing `OK` against the archived block markers.

The verdict phase reads the archived stage-12 quality result from the logs clone; if you keep a partial checkout, point `STAGE13_SRC12_DIR` at the stage-12 run directory.

## 3. Quality-gate verdict (stage 12 — single-shot confirmation)

```bash
bash ~/effiq/pilot004/stages/12-red-dot-confirm.sh --verify \
  ~/effiq/pilot-logs/2026-10-12/12-red-dot-confirm/run_1
```

Recomputes the verdict from the archived judge responses and blinding map only — no network, no API key, no GPU. The output must contain the per-judge table:

```
[judge: deepseek/deepseek-chat-v3-0324 (original red-dot judge)]  overall pooled delta (C - A): +0.013  ->  per-judge gate: PASS
[judge: z-ai/glm-4.6]                          overall pooled delta (C - A): +0.162  ->  per-judge gate: PASS
[judge: deepseek/deepseek-v3.1-terminus]       overall pooled delta (C - A): +0.056  ->  per-judge gate: PASS
```

```
worst overall: deepseek/deepseek-chat-v3-0324 (+0.013)
QUALITY GATE: PASS
```

plus the sha256 lines for `frozen_set.jsonl`, `gen_A.jsonl`, `gen_C.jsonl`, `judge_raw_c.jsonl`, and `blind_map.jsonl` (short forms in VERDICT.md §7).

## 4. Calibration and anchors (stage 10)

```bash
bash ~/effiq/pilot004/stages/10-preflight-calib.sh --verify \
  ~/effiq/pilot-logs/2026-10-12/10-preflight-calib/run_1
```

Verifies the nine anchor files (environment freeze, blind map, frozen set, screening set, calibration texts, H100-local reference generations, chosen operating point) and prints `VERIFY: ALL CHECKS PASSED`. The operating point itself (grid descent, ≥95% SLO compliance, fallback clause) is recomputed from the archived grid log.

## 5. Screening (stage 11)

```bash
bash ~/effiq/pilot004/stages/11-arm-screening.sh --verify \
  ~/effiq/pilot-logs/2026-10-12/11-arm-screening/run_1
```

Recomputes the screening table (five arms × 40 items), the winner selection (`b1-profile-exempt`, clarity +0.550 / overall +0.508), and the PROCEED outcome from the archived generations and judge responses.

## 6. What you cannot reproduce without the original accounts

- **The judge API calls themselves.** They are archived verbatim (`judge_raw_c.jsonl`, `judge_raw_screen.jsonl`); the `--verify` entries recompute the verdicts from those archives.
- **The GPU measurements.** Raw per-request archives (timing + token counts) are in the logs repository. Re-running the stages on your own H100 SXM under the same protocol produces *new* data — which we would genuinely welcome as an independent replication.
- **The recipe bodies.** Gate-layer by policy (VERDICT.md §9): labels and sha256 are public, bodies are not. Verification never needs them — every verdict is computable from the archives alone. The measured checkpoints were deleted after use by design; their sha256 anchors (`e59cd029…`, `539cee71…`) let anyone holding a recipe prove a rebuild is byte-identical.
- **The trace slice plans.** Bulk pod-local artifacts (`pair_1…6.jsonl`), reproducible from the public Azure LLM Inference Trace 2024 CSVs via `stages/01-trace-pipeline.sh --rebuild` in the Pilot 002 repository (hash-verified against the same anchors used here).

If your numbers differ from the ones quoted above, the archives you cloned differ from the ones we published — that is the point of the exercise.
