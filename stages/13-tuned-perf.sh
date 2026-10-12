#!/usr/bin/env bash
# =============================================================================
# Pilot 004 — STAGE 13: DUAL PERFORMANCE GATES (migration + retry, one stage)
#
# Frozen in PROTOCOL-LOCK v3.0. One measurement campaign answers both Pilot
# 004 performance questions under the SAME replayed production trace as
# Pilot 002 (stage-01 plans reused by hash; operating point = the H100
# recalibration produced by stage 10):
#   MIGRATION gate: arm B (stock FP8, vLLM --quantization fp8, exact Pilot
#     002 arm-B config) vs arm A (BF16) — paired-bootstrap 95% CI lower
#     bound >= 1.20x. Quality side is descriptive only (no gate).
#   RETRY gate: arm C (stage-12 confirmed winner) vs arm A — CI lower
#     bound >= 1.50x AND pooled P95 TPOT/TTFT non-inferiority (C/A <= 1.05)
#     AND the stage-12 quality gate (read from the archived verdict_c.json).
#     The 1.20x continuity figure is reported but does not decide.
#
# Frozen rules:
#   - Requires stage 12 COMPLETE (winner + recipe custody chain archived).
#   - n = 10 formal runs; NO straddle — n=10 is the final word. Declared
#     run-to-pair mapping: runs 1..6 replay slice pairs 1..6; run 7 replays
#     pair_3; runs 8..10 replay pairs 1, 2, 3. Rationale (declared, frozen
#     before measurement): the runs-as-units bootstrap stays valid under
#     declared repetition, and oversampling pair_3 (the heaviest, saturation-
#     regime slice) weights the commercially decision-relevant region; it is
#     conservative for the retry gate (escape costs concentrate there).
#   - Within-run 3-arm block crossover: odd runs A B C, even runs C B A
#     (frozen reading of "odd/even alternating lead"; mirror reversal). B is
#     always the middle block — declared; both gated comparisons (B/A, C/A)
#     see alternating outer positions across runs.
#   - Anchor arm K (a4-anchor, Pilot 003 winner rebuilt on H100): 2
#     descriptive-only runs on pairs 1 and 3 AFTER the formal runs. Never
#     enters any CI or gate.
#   - ANTI-P-HACKING: during measurement this stage prints DESCRIPTIVE
#     MEANS ONLY. The verdict phase runs only after all 10 RUN_COMPLETE
#     markers exist, and recomputes everything from raw JSONL.
#   - PILOT 004 VERDICT = migration gate AND retry gate (quality + perf).
#   - Run seeds: RUN_SEED_BASE=20265000 (distinct from 002's 20263000 and
#     003's 20264000). Bootstrap seed 20262002, 100,000 resamples (sealed
#     craft carried from 002/003).
#
# Fallback disclosure (carried): if the stage-10 H100 recalibration fell
# back to the lightest grid configuration, the shortfall disclosure follows
# the data into this verdict as well.
#
# Verify entry: bash stages/13-tuned-perf.sh --verify <run_dir>
#   Recomputes the verdict from raw archives and byte-compares (declared
#   normalization: archive paths, scripts_rev).
#
# Test hooks (sandbox only): STAGE13_OUT_DIR, STAGE13_SRC10_DIR,
#   STAGE13_SRC11_DIR, STAGE13_SRC12_DIR, STAGE13_SKIP_SERVER,
#   STAGE13_SKIP_PREFLIGHT, STAGE13_MOCK_BUILD, STAGE13_CHOSEN_JSON,
#   STAGE13_PLANS_DIR, STAGE13_SKIP_ANCHOR, PORT, RUNS, MAX_SECONDS,
#   RECIPES_FILE, CKPT_ROOT
# =============================================================================
set -euo pipefail

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"
GPU_EXPECT="H100"
MAX_MODEL_LEN=32768
MAX_TOKENS_CAP=1024            # frozen L2 cap (Pilot 002 craft)
N_RUNS=10                      # frozen; no straddle — n=10 is the final word
PAIR_MAP=(pair_1 pair_2 pair_3 pair_4 pair_5 pair_6 pair_3 pair_1 pair_2 pair_3)  # declared repetition, frozen
THRESH=1.50                    # frozen retry perf gate: CI lower bound >= 1.50x (C vs A)
THRESH_MIGRATION=1.20          # frozen migration gate: CI lower bound >= 1.20x (B vs A)
THRESH_PROTOCOL=1.20           # retry continuity reference (reported, does not decide)
BOOT_SEED=20262002             # same declared bootstrap seed as Pilot 002 stage 04
BOOT_N=100000
P95_TOL=1.05                   # retry secondary gate, carried over
SLO_TTFT_S=5.0                 # descriptive per-row SLO flag only
SLO_TPOT_MS=100.0
REQ_TIMEOUT_S=900
CLIENT_CONC="${CLIENT_CONC:-2048}"
FILLER_SEED=20261010           # same stream as stage-01 keep_u (frozen)
RUN_SEED_BASE=20265000         # Pilot 004 run seeds (distinct from 002's 20263000 / 003's 20264000)
ANCHOR_ARM="a4-anchor"         # Pilot 003 winner, H100 rebuild, descriptive only
ANCHOR_PAIRS=("pair_1" "pair_3")
MAX_SECONDS="${MAX_SECONDS:-57600}"   # ~16 h rail (2 builds + 32 blocks), resumable
PORT="${PORT:-8000}"           # test hook only
RUNS="${RUNS:-1 2 3 4 5 6 7 8 9 10}"  # test hook only

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot004}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="${STAGE13_PLANS_DIR:-$TRACE_DIR/plans}"
RECIPES_FILE="${RECIPES_FILE:-$HOME/pilot-env/arms-recipes.json}"
CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p004-ckpt}"
STAGE_NAME="13-tuned-perf"
DATE_STR="$(date -u +%Y-%m-%d)"
T0=$(date +%s)

say()  { printf '\n\033[1;36m[stage13] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[stage13][WARN] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage13][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  [ "$elapsed" -gt "$MAX_SECONDS" ] && \
    die "time rail tripped (${elapsed}s) — completed blocks carry .done markers; re-run the nightly command to resume."
  return 0
}

# ---------------- frozen anchors: stage-10 chosen_004 + stage-01 manifest + stage-12 winner ----------------
CHOSEN_JSON="${STAGE13_CHOSEN_JSON:-}"
if [ -z "$CHOSEN_JSON" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/10-preflight-calib/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && [ -f "$d/chosen_004.json" ] && CHOSEN_JSON="$d/chosen_004.json" && break
  done
fi
[ -n "$CHOSEN_JSON" ] && [ -f "$CHOSEN_JSON" ] \
  || die "stage-10 chosen_004.json not found — the H100 operating point is frozen there (run stage 10 first)"

read D_CHOSEN C_CHOSEN FALLBACK <<<"$(python3 -c "
import json; d = json.load(open('$CHOSEN_JSON'))
print(d['D'], d['C'], str(d.get('fallback', False)).lower())")"
WINDOW_S=$(( 3600 / C_CHOSEN ))
if [ "$FALLBACK" = "true" ]; then
  DISCLOSURE="no grid configuration met the SLO; lightest configuration used, shortfall disclosed per protocol"
else
  DISCLOSURE=""
fi

S01_DIR="$(ls -dt "$LOGS_DIR"/*/01-trace-pipeline/run_* 2>/dev/null | head -1 || true)"
[ -n "$S01_DIR" ] && [ -f "$S01_DIR/plans_manifest.json" ] \
  || die "Pilot 002 stage-01 plans_manifest.json not found — re-run 002 stage 01 first (byte-reproducible)"

SRC12_DIR="${STAGE13_SRC12_DIR:-}"
if [ -z "$SRC12_DIR" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/12-red-dot-confirm/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && SRC12_DIR="$d" && break
  done
fi
[ -n "$SRC12_DIR" ] || die "no COMPLETE stage-12 run found — the retry perf gate needs the confirmed candidate"
[ -f "$SRC12_DIR/winner.json" ] || die "stage-12 archive lacks winner.json"
WINNER_ARM=$(python3 -c "import json; print(json.load(open('$SRC12_DIR/winner.json'))['arm_id'])")
[ "$WINNER_ARM" != "b0-control" ] || die "stage-12 winner is the control arm — no tuned candidate (screening NO-GO should have stopped the pipeline)"
SRC11_DIR="${STAGE13_SRC11_DIR:-$(ls -dt "$LOGS_DIR"/*/11-arm-screening/run_* 2>/dev/null | head -1 || true)}"
[ -n "$SRC11_DIR" ] && [ -f "$SRC11_DIR/calibration_texts.jsonl" ] \
  || die "stage-11 calibration archive not found (needed for an identical rebuild)"

# ---------------- verdict phase (sealed until all runs complete; recomputes from raw) ----------------
run_verdict() {
  SRC_DIR="$RUN_DIR" CHOSEN_JSON="$CHOSEN_JSON" OUT_DIR="$RUN_DIR" \
  SRC12_DIR="$SRC12_DIR" THRESH="$THRESH" THRESH_MIGRATION="$THRESH_MIGRATION" \
  THRESH_PROTOCOL="$THRESH_PROTOCOL" \
  BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" P95_TOL="$P95_TOL" N_RUNS="$N_RUNS" \
  WINNER_ARM="$WINNER_ARM" ANCHOR_ARM="$ANCHOR_ARM" \
  GIT_REV="$SCRIPTS_REV" python3 - <<'PY'
import glob, hashlib, json, math, os, statistics, sys

SRC = os.environ["SRC_DIR"]; OUT = os.environ["OUT_DIR"]
THRESH = float(os.environ["THRESH"]); THRESH_M = float(os.environ["THRESH_MIGRATION"])
THRESH_P = float(os.environ["THRESH_PROTOCOL"])
BSEED = int(os.environ["BOOT_SEED"]); BN = int(os.environ["BOOT_N"])
P95TOL = float(os.environ["P95_TOL"]); N_RUNS = int(os.environ["N_RUNS"])
GREV = os.environ["GIT_REV"]
ARMS = ("A", "B", "C")

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

runs = {}
integrity = []
for rd in sorted(glob.glob(os.path.join(SRC, "formal_run_*")), key=lambda p: int(p.rsplit("_", 1)[1])):
    i = int(rd.rsplit("_", 1)[1])
    arms = {}
    pair = None
    for arm in ARMS:
        fp = os.path.join(rd, f"arm{arm}.jsonl"); mp = os.path.join(rd, f"arm{arm}.done")
        if not (os.path.exists(fp) and os.path.exists(mp)):
            sys.exit(f"FATAL: run {i} arm {arm} missing jsonl or .done marker — archive incomplete")
        marker = json.load(open(mp))
        integrity.append((f"run {i} arm {arm}", marker.get("raw_sha256", "") == sha(fp), sha(fp)[:16] + "…"))
        rows = {}
        for line in open(fp):
            r = json.loads(line)
            if "status" not in r:
                pair = pair or r.get("pair_id"); continue
            if r["status"] == "ok": rows[r["request_id"]] = r
        arms[arm] = rows
    runs[i] = {"A": arms["A"], "B": arms["B"], "C": arms["C"], "pair": pair}
bad = [n for n, ok, _ in integrity if not ok]
if bad: sys.exit(f"FATAL: raw archive hash mismatch vs block markers: {bad}")
if len(runs) < N_RUNS: sys.exit(f"FATAL: only {len(runs)} complete runs — need {N_RUNS} (no straddle; n=10 is the final word)")

import numpy as np

def paired_run_vals(x, y):
    """run-level mean of per-request log throughput ratios (x/y), runs as units."""
    vals, counts = [], []
    for i in sorted(runs):
        X, Y = runs[i][x], runs[i][y]
        common = sorted(set(X) & set(Y))
        lrs = [math.log((X[r]["completion_tokens"] / X[r]["e2e_s"]) /
                        (Y[r]["completion_tokens"] / Y[r]["e2e_s"])) for r in common]
        vals.append(statistics.mean(lrs)); counts.append(len(common))
    return vals, counts

def boot_ci(run_vals):
    vals = np.array(run_vals); point = float(vals.mean())
    rng = np.random.default_rng(BSEED)   # same declared seed for every comparison
    means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
    lo, hi = (float(x) for x in np.percentile(means, [2.5, 97.5]))
    return point, lo, hi

def p95(v):
    v = sorted(v); k = (len(v) - 1) * 0.95
    f, c = math.floor(k), math.ceil(k)
    return v[f] if f == c else v[f] + (v[c] - v[f]) * (k - f)

def pooled_p95(x, y):
    pool = {a: {"ttft": [], "tpot": []} for a in (x, y)}
    for i in runs:
        for arm in (x, y):
            for r in runs[i][arm].values():
                pool[arm]["ttft"].append(r["ttft_s"]); pool[arm]["tpot"].append(r["tpot_ms"])
    pt = {a: p95(pool[a]["tpot"]) for a in (x, y)}
    pf = {a: p95(pool[a]["ttft"]) for a in (x, y)}
    return pt, pf

# ---- migration: B (stock FP8) vs A (BF16), gate = CI lower bound >= 1.20x ----
ba_vals, ba_counts = paired_run_vals("B", "A")
ba_pt, ba_lo, ba_hi = boot_ci(ba_vals)
migration = "PASS" if ba_lo >= math.log(THRESH_M) else "FAIL"
ba_pt_tpot, ba_pt_ttft = pooled_p95("B", "A")   # descriptive, non-gate

# ---- retry: C (stage-12 winner) vs A (BF16), gates = CI >= 1.50x AND P95 non-inferiority ----
ca_vals, ca_counts = paired_run_vals("C", "A")
ca_pt, ca_lo, ca_hi = boot_ci(ca_vals)
primary = "PASS" if ca_lo >= math.log(THRESH) else "FAIL"
p95_tpot, p95_ttft = pooled_p95("C", "A")
tpot_ratio = p95_tpot["C"] / p95_tpot["A"]; ttft_ratio = p95_ttft["C"] / p95_ttft["A"]
secondary_ok = tpot_ratio <= P95TOL and ttft_ratio <= P95TOL
perf = "PASS" if (primary == "PASS" and secondary_ok) else "FAIL"

qgate = "UNKNOWN"
qpath = os.path.join(os.environ["SRC12_DIR"], "verdict_c.json")
if os.path.exists(qpath):
    qgate = json.load(open(qpath)).get("quality_gate", "UNKNOWN")
retry = "PASS" if (qgate == "PASS" and perf == "PASS") else "FAIL"
pilot004 = "PASS" if (migration == "PASS" and retry == "PASS") else "FAIL"

# ---- anchor arm K (a4-anchor): descriptive only, no CI, no gate ----
anchor_lines = []
anchor_data = {}
for apath in sorted(glob.glob(os.path.join(SRC, "anchor_run_*"))):
    apair = apath.rsplit("anchor_run_", 1)[1]
    fp = os.path.join(apath, "armK.jsonl")
    if not os.path.exists(fp):
        continue
    ok = [json.loads(l) for l in open(fp) if l.strip()]
    ok = [r for r in ok if r.get("status") == "ok"]
    if not ok:
        continue
    k_tps = statistics.mean(r["completion_tokens"] / r["e2e_s"] for r in ok)
    # descriptive comparison: arm A rows of the formal run(s) on the same pair
    a_tps = []
    for i in sorted(runs):
        if runs[i]["pair"] == apair:
            a_ok = [r for r in runs[i]["A"].values()]
            a_tps.extend(r["completion_tokens"] / r["e2e_s"] for r in a_ok)
    line = f"  {apair}: anchor mean tps={k_tps:.2f}"
    entry = {"anchor_mean_tps": round(k_tps, 6), "anchor_ok_rows": len(ok)}
    if a_tps:
        line += f" vs A mean tps={statistics.mean(a_tps):.2f} (same-pair formal runs; descriptive ratio {k_tps / statistics.mean(a_tps):.4f}x)"
        entry["a_mean_tps_same_pair"] = round(statistics.mean(a_tps), 6)
        entry["descriptive_ratio_vs_A"] = round(k_tps / statistics.mean(a_tps), 6)
    anchor_lines.append(line)
    anchor_data[apair] = entry

chosen = json.load(open(os.environ["CHOSEN_JSON"]))
L = []
L.append("STAGE 13 VERDICT — PILOT 004 DUAL PERFORMANCE GATES (migration + retry)")
L.append(f"computed from raw archives: {SRC}")
L.append(f"scripts_rev={GREV}  bootstrap seed={BSEED}  resamples={BN}")
L.append("no straddle — the n=10 paired bootstrap is the final word (run-to-pair mapping declared in the script header)")
if chosen.get("fallback"):
    L.append(f"disclosure (carried): operating point r=1/{chosen['D']}, C={chosen['C']}, shortfall disclosed per protocol")
L.append("")
L.append("[input integrity] per-block raw JSONL sha256 vs markers:")
for name, ok, short in integrity:
    L.append(f"  {name}: {'OK' if ok else 'MISMATCH'} ({short})")
L.append("")
L.append(f"[runs] n={len(runs)} formal runs; pairs: " + ", ".join(f"run {i}={runs[i]['pair']}" for i in sorted(runs)))
L.append("")
L.append(f"[migration gate] arm B (stock FP8) vs arm A (BF16) — rule: CI lower bound >= {THRESH_M}x")
L.append(f"  paired requests per run: {ba_counts}")
L.append("  run-level mean log-ratios (B/A): " + ", ".join(f"run {i}: {v:+.4f}" for i, v in zip(sorted(runs), ba_vals)))
L.append(f"  point estimate: exp(mean) = {math.exp(ba_pt):.4f}x")
L.append(f"  paired bootstrap 95% CI: exp([{ba_lo:+.4f}, {ba_hi:+.4f}]) = [{math.exp(ba_lo):.4f}, {math.exp(ba_hi):.4f}]x")
L.append(f"  MIGRATION GATE: {migration}")
L.append(f"  [descriptive, non-gate] pooled P95 TPOT B/A ratio={ba_pt_tpot['B'] / ba_pt_tpot['A']:.4f}, P95 TTFT B/A ratio={ba_pt_ttft['B'] / ba_pt_ttft['A']:.4f}")
L.append(f"  [descriptive, non-gate] quality side of the migration arm is not gated in Pilot 004;")
L.append(f"  the sealed Pilot 002 L40S result (2.33x) is cross-hardware context only, never a verdict input")
L.append("")
L.append(f"[retry gate] arm C ({os.environ['WINNER_ARM']}) vs arm A (BF16) — rule: CI lower bound >= {THRESH}x AND P95 non-inferiority (tol 5%)")
L.append(f"  paired requests per run: {ca_counts}")
L.append("  run-level mean log-ratios (C/A): " + ", ".join(f"run {i}: {v:+.4f}" for i, v in zip(sorted(runs), ca_vals)))
L.append(f"  point estimate: exp(mean) = {math.exp(ca_pt):.4f}x")
L.append(f"  paired bootstrap 95% CI: exp([{ca_lo:+.4f}, {ca_hi:+.4f}]) = [{math.exp(ca_lo):.4f}, {math.exp(ca_hi):.4f}]x")
L.append(f"  primary (CI >= {THRESH}x): {primary}")
L.append(f"  [continuity] vs {THRESH_P}x: {'PASS' if ca_lo >= math.log(THRESH_P) else 'FAIL'} (reported, does not decide)")
L.append(f"  [secondary] P95 TPOT: A={p95_tpot['A']:.2f}ms C={p95_tpot['C']:.2f}ms ratio={tpot_ratio:.4f}  {'OK' if tpot_ratio <= P95TOL else 'BREACH'}")
L.append(f"  [secondary] P95 TTFT: A={p95_ttft['A']:.3f}s C={p95_ttft['C']:.3f}s ratio={ttft_ratio:.4f}  {'OK' if ttft_ratio <= P95TOL else 'BREACH'}")
L.append(f"  PERFORMANCE (retry): {perf}")
L.append(f"  QUALITY GATE (stage 12, archived): {qgate}")
L.append(f"  RETRY GATE: {retry}")
if anchor_lines:
    L.append("")
    L.append(f"[anchor arm K: {os.environ['ANCHOR_ARM']} — descriptive only, no CI, no gate]")
    L.extend(anchor_lines)
L.append("")
L.append(f"PILOT 004 VERDICT: {pilot004}")
L.append("  (PASS requires the migration gate AND the retry gate; a FAIL here publishes in full per PROTOCOL-LOCK v3.0)")
L.append("")
L.append("Reproduce: bash stages/13-tuned-perf.sh --verify <run_dir>")
txt = "\n".join(L) + "\n"
open(os.path.join(OUT, "verdict_t.txt"), "w").write(txt)
json.dump(dict(stage="13-tuned-perf", pilot="004", scripts_rev=GREV,
               n_runs=len(runs),
               pair_map={str(i): runs[i]["pair"] for i in sorted(runs)},
               migration=dict(threshold=THRESH_M, paired_counts=ba_counts,
                              run_mean_log_ratios={str(i): v for i, v in zip(sorted(runs), ba_vals)},
                              point_estimate_ratio=math.exp(ba_pt), ci95_ratio=[math.exp(ba_lo), math.exp(ba_hi)],
                              gate=migration),
               retry=dict(candidate=os.environ["WINNER_ARM"], threshold=THRESH, threshold_continuity=THRESH_P,
                          paired_counts=ca_counts,
                          run_mean_log_ratios={str(i): v for i, v in zip(sorted(runs), ca_vals)},
                          point_estimate_ratio=math.exp(ca_pt), ci95_ratio=[math.exp(ca_lo), math.exp(ca_hi)],
                          primary=primary,
                          secondary=dict(p95_tpot_ms=p95_tpot, p95_ttft_s=p95_ttft,
                                         tpot_ratio=tpot_ratio, ttft_ratio=ttft_ratio, ok=secondary_ok),
                          perf_gate=perf, quality_gate=qgate, gate=retry),
               anchor_descriptive=anchor_data,
               pilot004_verdict=pilot004,
               input_sha256={f"run{i}_arm{a}": sha(os.path.join(SRC, f"formal_run_{i}", f"arm{a}.jsonl"))
                             for i in sorted(runs) for a in ARMS}),
          open(os.path.join(OUT, "verdict_t.json"), "w"), indent=2, sort_keys=True)
print(txt)
raise SystemExit(0 if pilot004 == "PASS" else 2)
PY
}

# ============================================================
# --verify mode: recompute the verdict from raw archives and byte-compare
# Declared normalization: archive paths, scripts_rev.
# ============================================================
if [ "${1:-}" = "--verify" ]; then
  VD="${2:-}"
  if [ -z "$VD" ]; then VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$VD" ] && [ -f "$VD/verdict_t.txt" ] || die "--verify: no verdict archive found (usage: --verify [run_dir])"
  say "--verify: recomputing from $VD raw archives"
  SRC12_DIR_V="$(ls -dt "$LOGS_DIR"/*/12-red-dot-confirm/run_* 2>/dev/null | head -1 || true)"
  TMPD="$(mktemp -d)"
  for i in $RUNS; do
    mkdir -p "$TMPD/formal_run_$i"
    cp "$VD/formal_run_$i"/armA.jsonl "$VD/formal_run_$i"/armA.done \
       "$VD/formal_run_$i"/armB.jsonl "$VD/formal_run_$i"/armB.done \
       "$VD/formal_run_$i"/armC.jsonl "$VD/formal_run_$i"/armC.done "$TMPD/formal_run_$i/"
  done
  for ad in "$VD"/anchor_run_*; do
    [ -d "$ad" ] || continue
    mkdir -p "$TMPD/$(basename "$ad")"
    cp "$ad"/armK.jsonl "$TMPD/$(basename "$ad")/" 2>/dev/null || true
  done
  RUN_DIR="$TMPD" SRC12_DIR="${SRC12_DIR_V:-$VD}" SCRIPTS_REV="verify" run_verdict > /dev/null || true
  python3 - "$VD" "$TMPD" <<'PY'
import json, re, sys
a, b = sys.argv[1], sys.argv[2]
def norm(t):
    t = re.sub(r"computed from raw archives: \S+", "computed from raw archives: NORMALIZED", t)
    t = re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
    return t
ta, tb = norm(open(a + "/verdict_t.txt").read()), norm(open(b + "/verdict_t.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
ja = json.load(open(a + "/verdict_t.json")); jb = json.load(open(b + "/verdict_t.json"))
for j in (ja, jb): j.pop("scripts_rev", None)
if ja != jb:
    print("VERIFY: MISMATCH (json)", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_t.txt / verdict_t.json identical (numbers byte-exact; declared provenance normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------------- run dir: resume-or-create ----------------
LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ -z "${STAGE13_OUT_DIR:-}" ] && [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  say "this stage is already COMPLETE — verdict preserved at:"
  echo "  $LATEST/verdict_t.txt"
  echo "  (to recompute from the raw archives: bash stages/13-tuned-perf.sh --verify)"
  exit 0
fi
if [ -n "${STAGE13_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE13_OUT_DIR"; mkdir -p "$RUN_DIR"
elif [ -n "$LATEST" ]; then
  RUN_DIR="$LATEST"; say "resuming incomplete run dir: $RUN_DIR"
else
  BASE="$LOGS_DIR/$DATE_STR/$STAGE_NAME"; mkdir -p "$BASE"
  N=1; while [ -e "$BASE/run_$N" ]; do N=$((N+1)); done
  RUN_DIR="$BASE/run_$N"; mkdir -p "$RUN_DIR"
fi

# ---------------- preflight asserts ----------------
say "preflight asserts"
if [ "${STAGE13_SKIP_PREFLIGHT:-0}" != "1" ]; then
  nvidia-smi --query-gpu=name --format=csv,noheader | grep -q "$GPU_EXPECT" \
    || die "GPU is not $GPU_EXPECT — hardware boundary is locked (L3)"
  python3 -c "import vllm, sys; v=vllm.__version__; sys.exit(0 if v=='$VLLM_PINNED' else 1)" \
    || die "vLLM is not $VLLM_PINNED — engine version is pinned (L1)"
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${FREE_GB:-0}" -ge 80 ] || die "disk headroom < 80GB (base weights + two checkpoints: winner + a4-anchor)"
fi
python3 -c "import httpx" 2>/dev/null || die "httpx not importable (expected present with vLLM)"
ulimit -n 65536 2>/dev/null || warn "could not raise fd limit (continuing with $(ulimit -n))"
SCRIPTS_REV="$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)"
[ -f "$RECIPES_FILE" ] || die "private recipes file missing: $RECIPES_FILE (pod-side custody)"

# ---------------- anchor check: 6 formal plans vs stage-01 manifest ----------------
say "anchor check: 6 formal plans vs Pilot 002 stage-01 manifest"
S01_DIR="$S01_DIR" PLANS_DIR="$PLANS_DIR" python3 - <<'PY'
import hashlib, json, os, sys
man = json.load(open(os.path.join(os.environ["S01_DIR"], "plans_manifest.json")))
plans = man["plans"] if "plans" in man else man
bad = []
for i in range(1, 7):
    pid = f"pair_{i}"
    entry = plans.get(pid) or {}
    path = os.path.join(os.environ["PLANS_DIR"], f"{pid}.jsonl")
    if not os.path.exists(path):
        bad.append(f"{pid}: missing {path} — re-run Pilot 002 stage 01 (byte-reproducible)"); continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    want = entry.get("merged_sha256")
    if not (want and h.hexdigest() == want):
        bad.append(f"{pid}: sha256 mismatch vs manifest")
    print(f"  [{pid}] sha256={h.hexdigest()[:16]}… {'OK' if not bad or pid not in bad[-1] else 'MISMATCH'}")
if bad:
    sys.exit("\n".join(bad))
PY
[ $? -eq 0 ] || die "plan anchor check failed"

# ---------------- candidate checkpoints: arm C (winner) + arm K (a4-anchor, descriptive) ----------------
LOCAL_RECIPE_LOG="$CKPT_ROOT/recipes-local.jsonl"   # pod-local, NEVER pushed (same path as stages 11/12)

# build_perf_ckpt ARM_ID CKPT_DIR CKPT_LOG WANT_SHA
# WANT_SHA non-empty = custody pin (winner: stage-12 winner.json recipe_sha256).
# WANT_SHA empty = anchor arm: recipe from the gate-layer file, sha recorded as provenance.
build_perf_ckpt() {
  local arm="$1" cdir="$2" clog="$3" want_sha="$4"
  if [ -f "$clog" ] && [ -d "$cdir" ]; then
    echo "checkpoint for $arm present: $(python3 -c "import json; print(json.load(open('$clog'))['checkpoint_sha256'][:16])")… — resume"
    return 0
  fi
  [ -f "$clog" ] && warn "marker exists but checkpoint dir wiped — rebuilding $arm from the identical recipe"
  rm -f "$clog"
  # Recipe resolution + custody pin run ALWAYS (cheap, no GPU). Mock mode fakes only
  # the weight build — a broken custody chain must fail loudly in every mode.
  RESOLVED_JSON="$cdir.resolved-recipe.json"   # pod-local temp; deleted after use
  ARM_ID="$arm" WANT_SHA="$want_sha" RECIPES_FILE="$RECIPES_FILE" LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" \
  RESOLVED_JSON="$RESOLVED_JSON" python3 - <<'PY'
import hashlib, json, os, sys
arm = os.environ["ARM_ID"]; want_sha = os.environ["WANT_SHA"] or None
recs = json.load(open(os.environ["RECIPES_FILE"]))["recipes"]
def canon(r): return hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if arm in recs:
    r = recs[arm]
else:
    # composed arm (b1/b2 profile-exempt, b4-w2 merge): exact body from the pod-local
    # recipe log written by stage 11 (append-only; LAST match is current) — same
    # custody pattern as stage 12, no second derivation path
    r = None
    rlog = os.environ.get("LOCAL_RECIPE_LOG", "")
    if rlog and os.path.exists(rlog):
        for l in open(rlog):
            if l.strip():
                e = json.loads(l)
                if e.get("arm_id") == arm:
                    r = e.get("recipe")
    if r is None:
        sys.exit(f"FATAL: recipe for {arm} not in the recipes file and no pod-local body in {rlog} — custody chain broken")
got = canon(r)
if want_sha and got != want_sha:
    sys.exit(f"FATAL: resolved recipe sha256 {got} != screening record {want_sha} — custody chain broken, owner decision required")
json.dump(r, open(os.environ["RESOLVED_JSON"], "w"), indent=2, sort_keys=True)
PY
  if [ "${STAGE13_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$cdir"; echo '{"mock": true}' > "$cdir/config.json"
    RECIPE_SHA=$(python3 -c "import hashlib, json; print(hashlib.sha256(json.dumps(json.load(open('$RESOLVED_JSON')), sort_keys=True, separators=(',', ':')).encode()).hexdigest())")
    rm -f "$RESOLVED_JSON"
    python3 -c "
import json
json.dump(dict(arm_id='$arm', checkpoint_dir='$cdir', checkpoint_sha256='mock-$arm', recipe_sha256='$RECIPE_SHA', mock=True),
          open('$clog', 'w'), indent=2)"
    echo "TEST HOOK: mock checkpoint for $arm at $cdir (recipe custody verified)"
    return 0
  fi
  ARM_ID="$arm" WANT_SHA="$want_sha" RESOLVED_JSON="$RESOLVED_JSON" \
  CKPT_DIR="$cdir" CALIB_JSONL="$SRC11_DIR/calibration_texts.jsonl" \
  MODEL="$MODEL" MODEL_REV="$MODEL_REV" CKPT_LOG="$clog" python3 - <<'PY'
import hashlib, json, os, sys, time
arm = os.environ["ARM_ID"]; want_sha = os.environ["WANT_SHA"] or None
def canon(r): return hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
# single resolution already happened above (custody pin enforced there); re-assert cheaply
r = json.load(open(os.environ["RESOLVED_JSON"]))
got = canon(r)
if want_sha and got != want_sha:
    sys.exit(f"FATAL: resolved recipe sha256 {got} != screening record {want_sha} — custody chain broken, owner decision required")
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_JSONL"])]
from datasets import Dataset as _HFDS
def _hfds_from_texts(texts):
    return _HFDS.from_list([{"text": t} for t in texts])

assert len(calib) == 256, f"calibration archive row count {len(calib)} != 256"
try:
    import llmcompressor
    from llmcompressor import oneshot
    from llmcompressor.modifiers.quantization import QuantizationModifier
    ver = llmcompressor.__version__
except ImportError:
    raise SystemExit("llmcompressor not installed — install it on the pod (builder version is provenance)")
mods = []
if "smoothing" in r:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    mods.append(SmoothQuantModifier(smoothing_strength=r["smoothing"]["strength"]))
q = r["quantization"]
q_kwargs = dict(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"])
if "kv_cache_scheme" in r:
    # b3-class arms: calibrated FP8 KV cache (llmcompressor 0.12.0 QuantizationModifier
    # accepts kv_cache_scheme as QuantizationArgs — verified against the wheel source)
    from compressed_tensors.quantization import QuantizationArgs
    q_kwargs["kv_cache_scheme"] = QuantizationArgs(**r["kv_cache_scheme"])
mods.append(QuantizationModifier(**q_kwargs))
t0 = time.time()
oneshot(model=os.environ["MODEL"], model_revision=os.environ["MODEL_REV"],
        dataset=_hfds_from_texts(calib), recipe=mods, output_dir=os.environ["CKPT_DIR"],
        num_calibration_samples=r["calibration"]["n_samples"],
        max_seq_length=r["calibration"]["max_seq_len"])
def tree_sha(root):
    h = hashlib.sha256()
    for dp, _, fns in sorted(os.walk(root)):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
    return h.hexdigest()
csha = tree_sha(os.environ["CKPT_DIR"])
json.dump(dict(arm_id=arm, recipe_sha256=got, llmcompressor_version=ver,
               checkpoint_dir=os.environ["CKPT_DIR"], checkpoint_sha256=csha,
               build_seconds=round(time.time() - t0, 1),
               ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
          open(os.environ["CKPT_LOG"], "w"), indent=2, sort_keys=True)
print(f"perf checkpoint built for {arm}: sha256={csha[:16]}…")
PY
  rm -f "$RESOLVED_JSON"
}

say "candidate checkpoint for arm C (winner: $WINNER_ARM; custody pin = stage-12 winner.json recipe sha)"
CKPT_DIR="$CKPT_ROOT/${WINNER_ARM}-perf"
CKPT_LOG="$RUN_DIR/checkpoint_perf.json"
WINNER_RECIPE_SHA="$(python3 -c "import json; print(json.load(open('$SRC12_DIR/winner.json')).get('recipe_sha256') or '')")"
build_perf_ckpt "$WINNER_ARM" "$CKPT_DIR" "$CKPT_LOG" "$WINNER_RECIPE_SHA"

if [ "${STAGE13_SKIP_ANCHOR:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE13_SKIP_ANCHOR=1 — a4-anchor build + descriptive runs skipped (sandbox only)"
else
  say "anchor checkpoint for arm K ($ANCHOR_ARM; descriptive only, sha from the gate-layer file)"
  ANCHOR_CKPT_DIR="$CKPT_ROOT/${ANCHOR_ARM}-perf"
  ANCHOR_CKPT_LOG="$RUN_DIR/checkpoint_anchor.json"
  build_perf_ckpt "$ANCHOR_ARM" "$ANCHOR_CKPT_DIR" "$ANCHOR_CKPT_LOG" ""
fi

# ---------------- vLLM server lifecycle (per arm block) ----------------
ANCHOR_CKPT_DIR="${ANCHOR_CKPT_DIR:-}"   # empty when STAGE13_SKIP_ANCHOR=1 (anchor blocks never run then)
start_server() {   # $1 = arm (A|B|C|K)
  local arm="$1"
  local slog="$RUN_DIR/server_run${CUR_RUN}_arm${arm}.log"
  local desc argv_model
  case "$arm" in
    A) desc="BF16 defaults";;
    B) desc="stock FP8 (vLLM --quantization fp8, exact Pilot 002 arm-B config)";;
    C) desc="tuned candidate ($WINNER_ARM)";;
    K) desc="anchor $ANCHOR_ARM (descriptive)";;
  esac
  say "run ${CUR_RUN}: starting Arm ${arm} server ($desc; prefix caching OFF)"
  case "$arm" in
    C) nohup python -m vllm.entrypoints.openai.api_server \
         --model "$CKPT_DIR" --quantization compressed-tensors \
         --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
         --port "$PORT" > "$slog" 2>&1 &
       echo "server_argv: vllm serve $CKPT_DIR --quantization compressed-tensors --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
         > "$RUN_DIR/${RUN_SUBDIR:-formal_run_${CUR_RUN}}/server_argv_arm${arm}.txt";;
    K) nohup python -m vllm.entrypoints.openai.api_server \
         --model "$ANCHOR_CKPT_DIR" --quantization compressed-tensors \
         --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
         --port "$PORT" > "$slog" 2>&1 &
       echo "server_argv: vllm serve $ANCHOR_CKPT_DIR --quantization compressed-tensors --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
         > "$RUN_DIR/${RUN_SUBDIR:-formal_run_${CUR_RUN}}/server_argv_arm${arm}.txt";;
    B) nohup python -m vllm.entrypoints.openai.api_server \
         --model "$MODEL" --revision "$MODEL_REV" --quantization fp8 \
         --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
         --port "$PORT" > "$slog" 2>&1 &
       echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --quantization fp8 --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
         > "$RUN_DIR/${RUN_SUBDIR:-formal_run_${CUR_RUN}}/server_argv_arm${arm}.txt";;
    *) nohup python -m vllm.entrypoints.openai.api_server \
         --model "$MODEL" --revision "$MODEL_REV" \
         --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
         --port "$PORT" > "$slog" 2>&1 &
       echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
         > "$RUN_DIR/${RUN_SUBDIR:-formal_run_${CUR_RUN}}/server_argv_arm${arm}.txt";;
  esac
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "server process died — see $slog"; fi
  done
  say "run ${CUR_RUN}: Arm ${arm} server healthy after ${waited}s"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------------- per-block replay client (identical craft to Pilot 002 stage 03) ----------------
run_block() {   # $1 = run_idx, $2 = arm (A|B|C|K), $3 = pair_id; RUN_SUBDIR env overrides the output subdir (anchor runs)
RUN_IDX="$1" ARM="$2" PAIR_ID="$3" \
RUN_DIR="$RUN_DIR" RUN_SUBDIR="${RUN_SUBDIR:-}" PLANS_DIR="$PLANS_DIR" PORT="$PORT" MODEL="$MODEL" \
CKPT_DIR="$CKPT_DIR" ANCHOR_CKPT_DIR="$ANCHOR_CKPT_DIR" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" \
SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" \
REQ_TIMEOUT_S="$REQ_TIMEOUT_S" CLIENT_CONC="$CLIENT_CONC" \
MAX_TOKENS_CAP="$MAX_TOKENS_CAP" MAX_MODEL_LEN="$MAX_MODEL_LEN" \
FILLER_SEED="$FILLER_SEED" RUN_SEED_BASE="$RUN_SEED_BASE" \
SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import asyncio, hashlib, json, os, random, sys, time
import httpx

RUN_DIR   = os.environ["RUN_DIR"]
RUN_IDX   = int(os.environ["RUN_IDX"])
ARM       = os.environ["ARM"]
PAIR_ID   = os.environ["PAIR_ID"]
PLAN      = os.path.join(os.environ["PLANS_DIR"], f"{PAIR_ID}.jsonl")
PORT      = os.environ["PORT"]
D0, C0    = int(os.environ["D_CHOSEN"]), int(os.environ["C_CHOSEN"])
R         = 1.0 / D0
WINDOW    = float(os.environ["WINDOW_S"])
FB        = os.environ["FALLBACK"] == "true"
DISC      = os.environ["DISCLOSURE"]
TTFT_SLO  = float(os.environ["SLO_TTFT_S"])
TPOT_SLO  = float(os.environ["SLO_TPOT_MS"])
REQ_TO    = float(os.environ["REQ_TIMEOUT_S"])
CONC      = int(os.environ["CLIENT_CONC"])
CAP       = int(os.environ["MAX_TOKENS_CAP"])
MML       = int(os.environ["MAX_MODEL_LEN"])
FSEED     = int(os.environ["FILLER_SEED"])
RUN_SEED  = int(os.environ["RUN_SEED_BASE"]) + RUN_IDX
SREV      = os.environ["SCRIPTS_REV"]
URL       = f"http://127.0.0.1:{PORT}/v1/completions"
SRV_MODEL = {"C": os.environ["CKPT_DIR"], "K": os.environ["ANCHOR_CKPT_DIR"]}.get(ARM, os.environ["MODEL"])

RD      = os.path.join(RUN_DIR, os.environ.get("RUN_SUBDIR") or f"formal_run_{RUN_IDX}")
RAW     = os.path.join(RD, f"arm{ARM}.jsonl")
DONE_F  = os.path.join(RD, f"arm{ARM}.done")
FAIL_F  = os.path.join(RD, f"arm{ARM}.failed")

rows = [json.loads(l) for l in open(PLAN)]
rows.sort(key=lambda r: (r["arrival_offset_s"], r["service"], r["request_id"]))
sched = [(row["arrival_offset_s"] / C0, row) for row in rows if row["keep_u"] < R]
n_sched = len(sched)
max_ctx = max(r["context_tokens"] for _, r in sched) if sched else 8192
print(f"[run {RUN_IDX} arm {ARM}] {PAIR_ID}: merged {len(rows):,} rows → thinned "
      f"{n_sched:,} offered over {WINDOW:.0f}s (≈{n_sched / WINDOW:.2f} req/s), "
      f"max ctx {max_ctx:,}", flush=True)

_rng = random.Random(FSEED)
_base = [_rng.randrange(1000, 50000) for _ in range(8192)]
G = (_base * (max_ctx // 8192 + 2))[: max_ctx + 8192]
def filler_ids(n, rid):
    off = int.from_bytes(hashlib.sha256(f"{FSEED}|{rid}".encode()).digest()[:4], "big") % 8192
    return G[off:off + n]

sent = done = errs = 0
fatal = []
t0 = time.monotonic()

async def replay(client, raw_f):
    global sent, done, errs
    sem = asyncio.Semaphore(CONC)

    async def fire(at, row):
        global sent, done, errs
        rid  = row["request_id"]
        ctx, gen = row["context_tokens"], row["generated_tokens"]
        rec = {"request_id": rid, "pair_id": PAIR_ID, "service": row["service"],
               "arrival_offset_s": row["arrival_offset_s"],
               "prompt_tokens": ctx, "max_tokens_target": min(gen, CAP, MML - ctx - 1),
               "arm": ARM, "run_idx": RUN_IDX, "run_seed": RUN_SEED,
               "scripts_rev": SREV, "D": D0, "C": C0}
        if rec["max_tokens_target"] <= 0:
            rec.update(status="skipped_overlength", completion_tokens=0,
                       ttft_s=None, tpot_ms=None, e2e_s=None,
                       wall_send_ts=None, wall_first_ts=None, wall_end_ts=None,
                       output_text_sha256=None, send_lag_ms=None, slo_ok=False,
                       retries=0)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            return
        async with sem:
            if fatal:
                return
            sent += 1
            payload = {"model": SRV_MODEL, "prompt": filler_ids(ctx, rid),
                       "max_tokens": rec["max_tokens_target"], "ignore_eos": True,
                       "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True}}
            t_send_m = time.monotonic(); wall_send = time.time()
            t_first_m = t_last_m = None; wall_first = None
            comp_tokens = 0
            texth = hashlib.sha256()
            status = "ok"; retries = 0
            try:
                attempt = 0
                while True:
                    try:
                        async with client.stream("POST", URL, json=payload) as resp:
                            if resp.status_code >= 500:
                                status = f"http_{resp.status_code}"
                                fatal.append(status)
                                break
                            if resp.status_code != 200:
                                status = f"http_{resp.status_code}"
                                break
                            async for line in resp.aiter_lines():
                                if not line.startswith("data:"):
                                    continue
                                data = line[5:].strip()
                                if data == "[DONE]":
                                    break
                                now_m = time.monotonic()
                                try:
                                    obj = json.loads(data)
                                except Exception:
                                    continue
                                if t_first_m is None:
                                    t_first_m = now_m; wall_first = time.time()
                                t_last_m = now_m
                                for ch in obj.get("choices", []):
                                    t = ch.get("text")
                                    if t:
                                        texth.update(t.encode())
                                u = obj.get("usage")
                                if u:
                                    comp_tokens = u.get("completion_tokens", comp_tokens)
                        break
                    except httpx.ConnectError:
                        attempt += 1
                        if attempt > 3:
                            status = "error:ConnectError"; break
                        retries = attempt
                        await asyncio.sleep(0.5 * attempt)
            except asyncio.CancelledError:
                rec.update(status="cancelled", completion_tokens=comp_tokens,
                           ttft_s=None, tpot_ms=None, e2e_s=None,
                           wall_send_ts=round(wall_send, 3), wall_first_ts=None,
                           wall_end_ts=round(time.time(), 3),
                           output_text_sha256=None,
                           send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                           slo_ok=False, retries=retries)
                raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
                done += 1
                raise
            except Exception as e:
                status = "error:" + type(e).__name__
            t_end_m = time.monotonic(); wall_end = time.time()
            if comp_tokens == 0 and status == "ok":
                status = "error:no_tokens"
            ttft = (t_first_m - t_send_m) if t_first_m is not None else None
            if t_first_m is not None and comp_tokens > 1:
                tpot_ms = (t_last_m - t_first_m) / (comp_tokens - 1) * 1000.0
            elif t_first_m is not None:
                tpot_ms = (t_end_m - t_first_m) * 1000.0
            else:
                tpot_ms = None
            e2e = t_end_m - t_send_m
            ok = (status == "ok" and ttft is not None and ttft <= TTFT_SLO
                  and tpot_ms is not None and tpot_ms <= TPOT_SLO)
            rec.update(status=status, completion_tokens=comp_tokens,
                       ttft_s=round(ttft, 4) if ttft is not None else None,
                       tpot_ms=round(tpot_ms, 3) if tpot_ms is not None else None,
                       e2e_s=round(e2e, 4),
                       wall_send_ts=round(wall_send, 3),
                       wall_first_ts=round(wall_first, 3) if wall_first else None,
                       wall_end_ts=round(wall_end, 3),
                       output_text_sha256=(texth.hexdigest() if status == "ok" else None),
                       send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                       slo_ok=ok, retries=retries)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            if status != "ok":
                errs += 1

    async def sender():
        for at, row in sched:
            if fatal:
                break
            delay = at - (time.monotonic() - t0)
            if delay > 0:
                await asyncio.sleep(delay)
            asyncio.create_task(fire(at, row))

    async def progress():
        while done < n_sched and not fatal:
            await asyncio.sleep(30)
            print(f"  [run {RUN_IDX} arm {ARM}] t={time.monotonic()-t0:.0f}s "
                  f"sent={sent} done={done}/{n_sched} errors={errs}", flush=True)

    sd = asyncio.create_task(sender())
    pg = asyncio.create_task(progress())
    await sd
    pending = {t for t in asyncio.all_tasks()
               if t is not asyncio.current_task() and t not in (sd, pg)}
    deadline = time.monotonic() + REQ_TO + 120.0
    while pending:
        if fatal or time.monotonic() > deadline:
            for t in pending:
                t.cancel()
        _, pending = await asyncio.wait(
            pending, timeout=5.0, return_when=asyncio.FIRST_COMPLETED)
    pg.cancel()

async def main():
    limits = httpx.Limits(max_connections=CONC,
                          max_keepalive_connections=min(CONC, 256))
    timeout = httpx.Timeout(REQ_TO, connect=30.0)
    hdr = {"type": "header", "pair_id": PAIR_ID, "arm": ARM, "run_idx": RUN_IDX,
           "run_seed": RUN_SEED, "scripts_rev": SREV, "D": D0, "C": C0,
           "r": f"1/{D0}", "window_s": WINDOW, "fallback": FB,
           "disclosure": DISC if FB else "",
           "slo_reference": {"ttft_s": TTFT_SLO, "tpot_ms": TPOT_SLO},
           "started_wall": round(time.time(), 3)}
    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        with open(RAW, "w") as raw_f:
            raw_f.write(json.dumps(hdr) + "\n")
            await replay(client, raw_f)
    if fatal:
        marker = {"arm": ARM, "status": "failed-server-error", "reason": fatal[0],
                  "rows": done, "note": "run voided (server-side error); re-run the "
                                        "nightly command after the cause is fixed — "
                                        "the block replays against identical load"}
        json.dump(marker, open(FAIL_F, "w"), indent=2)
        print(f"[run {RUN_IDX} arm {ARM}] VOIDED — server-side error {fatal[0]}", flush=True)
        sys.exit(45)
    ok_rows = errs_n = 0
    tps_sum = ttft_sum = tpot_sum = e2e_sum = 0.0
    comp_sum = 0
    with open(RAW) as f:
        for ln in f:
            r = json.loads(ln)
            if "status" not in r:
                continue
            if r["status"] == "ok":
                ok_rows += 1
                tps_sum  += r["completion_tokens"] / r["e2e_s"]
                ttft_sum += r["ttft_s"]; e2e_sum += r["e2e_s"]
                comp_sum += r["completion_tokens"]
                if r["tpot_ms"] is not None:
                    tpot_sum += r["tpot_ms"]
            elif r["status"] != "skipped_overlength":
                errs_n += 1
    raw_sha = hashlib.sha256(open(RAW, "rb").read()).hexdigest()
    marker = {"arm": ARM, "status": "ok", "rows": done,
              "ok": ok_rows, "errors": errs_n,
              "mean_tps": round(tps_sum / max(ok_rows, 1), 6),
              "mean_ttft_s": round(ttft_sum / max(ok_rows, 1), 6),
              "mean_tpot_ms": round(tpot_sum / max(ok_rows, 1), 6),
              "mean_e2e_s": round(e2e_sum / max(ok_rows, 1), 6),
              "completion_tokens_total": comp_sum,
              "scheduled": n_sched, "window_s": WINDOW,
              "raw_sha256": raw_sha, "raw_file": os.path.basename(RAW)}
    json.dump(marker, open(DONE_F, "w"), indent=2)
    print(f"[run {RUN_IDX} arm {ARM}] block ok: rows={done} ok={ok_rows} "
          f"errors={errs_n} mean_tps={marker['mean_tps']:.2f} raw_sha={raw_sha[:16]}…",
          flush=True)

asyncio.run(main())
PY
}

# ---------------- run summary (descriptive means only — verdict stays sealed) ----------------
summarize_run() {   # $1 = run_idx
RUN_IDX="$1" RUN_DIR="$RUN_DIR" RUN_SEED_BASE="$RUN_SEED_BASE" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import json, os
RUN_IDX = int(os.environ["RUN_IDX"])
RD = os.path.join(os.environ["RUN_DIR"], f"formal_run_{RUN_IDX}")
def rows(arm):
    out = []
    for ln in open(os.path.join(RD, f"arm{arm}.jsonl")):
        r = json.loads(ln)
        if "status" in r:
            out.append(r)
    return out
def mean(xs): return sum(xs) / len(xs) if xs else 0.0
ra, rb, rc = rows("A"), rows("B"), rows("C")
order = ["A", "B", "C"] if RUN_IDX % 2 == 1 else ["C", "B", "A"]
summ = {"run_idx": RUN_IDX, "pair_id": ra[0]["pair_id"] if ra else (rb[0]["pair_id"] if rb else rc[0]["pair_id"]),
        "run_seed": int(os.environ["RUN_SEED_BASE"]) + RUN_IDX,
        "arm_order": order, "D": int(os.environ["D_CHOSEN"]),
        "C": int(os.environ["C_CHOSEN"]), "window_s": float(os.environ["WINDOW_S"]),
        "fallback": os.environ["FALLBACK"] == "true",
        "disclosure": os.environ["DISCLOSURE"],
        "scripts_rev": os.environ["SCRIPTS_REV"], "note": "descriptive means only; "
        "the paired-bootstrap CIs (seed 20262002) and the P95 gate are computed "
        "exclusively by the sealed verdict phase of this stage"}
per_arm = {}
for arm, rr in (("A", ra), ("B", rb), ("C", rc)):
    ok = [r for r in rr if r["status"] == "ok"]
    per_arm[arm] = {
        "rows": len(rr), "ok": len(ok),
        "errors": sum(1 for r in rr if r["status"] not in ("ok", "skipped_overlength")),
        "skipped_overlength": sum(1 for r in rr if r["status"] == "skipped_overlength"),
        "mean_tps": round(mean([r["completion_tokens"] / r["e2e_s"] for r in ok]), 6),
        "mean_ttft_s": round(mean([r["ttft_s"] for r in ok]), 6),
        "mean_tpot_ms": round(mean([r["tpot_ms"] for r in ok if r["tpot_ms"] is not None]), 6),
        "mean_e2e_s": round(mean([r["e2e_s"] for r in ok]), 6),
    }
summ["per_arm"] = per_arm
oka = {r["request_id"]: r for r in ra if r["status"] == "ok"}
for x, rx in (("B", rb), ("C", rc)):
    okx = {r["request_id"]: r for r in rx if r["status"] == "ok"}
    both = [(okx[k], oka[k]) for k in oka.keys() & okx.keys()]
    ratios = [(c["completion_tokens"] / c["e2e_s"]) / (a["completion_tokens"] / a["e2e_s"]) for c, a in both]
    summ[f"paired_ok_requests_{x}A"] = len(both)
    summ[f"paired_mean_ratio_{x}_over_A"] = round(mean(ratios), 6)
json.dump(summ, open(os.path.join(RD, "run_summary.json"), "w"), indent=2)
print(f"[run {RUN_IDX}] summary: paired_ok B/A={summ['paired_ok_requests_BA']} C/A={summ['paired_ok_requests_CA']} "
      f"mean_tps A={per_arm['A']['mean_tps']:.2f} B={per_arm['B']['mean_tps']:.2f} C={per_arm['C']['mean_tps']:.2f} "
      f"descriptive paired mean ratios B/A={summ['paired_mean_ratio_B_over_A']:.4f} "
      f"C/A={summ['paired_mean_ratio_C_over_A']:.4f} (descriptive only — CIs sealed)", flush=True)
PY
}

# ---------------- main driver: 10 runs × 3 arm blocks, odd/even mirror crossover ----------------
say "starting dual-gate measurement: $N_RUNS runs × arms A/B/C, operating point r=1/${D_CHOSEN} C=${C_CHOSEN}"
say "declared run-to-pair map: ${PAIR_MAP[*]} (runs 1-6 = pairs 1-6; run 7 = pair_3; runs 8-10 = pairs 1,2,3)"
[ "$FALLBACK" = "true" ] && say "disclosure (carried into every summary): $DISCLOSURE"

if [ "${STAGE13_SKIP_SERVER:-0}" != "1" ]; then
  trap stop_server EXIT
else
  warn "STAGE13_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
fi

for CUR_RUN in $RUNS; do
  [ "$CUR_RUN" -ge 1 ] && [ "$CUR_RUN" -le "$N_RUNS" ] || die "run index $CUR_RUN outside 1..$N_RUNS — no extension is pre-registered for Pilot 004"
  check_time_rail
  RD="$RUN_DIR/formal_run_$CUR_RUN"
  mkdir -p "$RD"
  PAIR_ID="${PAIR_MAP[$((CUR_RUN-1))]}"
  [ -f "$PLANS_DIR/$PAIR_ID.jsonl" ] || die "plan missing: $PLANS_DIR/$PAIR_ID.jsonl — re-run stage 10 (plan custody chain)"
  if [ $(( CUR_RUN % 2 )) -eq 1 ]; then ARMS="A B C"; else ARMS="C B A"; fi
  say "run $CUR_RUN / $N_RUNS — $PAIR_ID, arm order: $ARMS"
  RUN_SUBDIR=""
  for ARM in $ARMS; do
    if [ -f "$RD/arm${ARM}.done" ]; then
      echo "  [run $CUR_RUN arm $ARM] already done (resume)"; continue
    fi
    if [ -f "$RD/arm${ARM}.failed" ]; then
      warn "run $CUR_RUN arm $ARM: previous attempt voided by server-side error — replaying identical load"
      rm -f "$RD/arm${ARM}.failed" "$RD/arm${ARM}.jsonl"
    fi
    check_time_rail
    if [ "${STAGE13_SKIP_SERVER:-0}" != "1" ]; then
      start_server "$ARM"
    fi
    set +e
    run_block "$CUR_RUN" "$ARM" "$PAIR_ID"
    RC=$?
    set -e
    if [ "$RC" -eq 45 ]; then
      [ "${STAGE13_SKIP_SERVER:-0}" != "1" ] && stop_server || true
      die "run $CUR_RUN arm $ARM voided by server-side error — incident recorded in $RD/arm${ARM}.failed + server log; enters the deviation log. Re-run the nightly command after the cause is fixed."
    fi
    [ "$RC" -eq 0 ] || die "block client failed (rc=$RC) — see stage.log"
    if [ "${STAGE13_SKIP_SERVER:-0}" != "1" ]; then
      if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then
        warn "run $CUR_RUN arm $ARM: server process exited during/after block — see server_run${CUR_RUN}_arm${ARM}.log"
      fi
      stop_server
    fi
  done
  if [ -f "$RD/armA.done" ] && [ -f "$RD/armB.done" ] && [ -f "$RD/armC.done" ]; then
    summarize_run "$CUR_RUN"
    echo "ok" > "$RD/RUN_COMPLETE"
  fi
done

# ---------------- anchor arm K: descriptive-only runs (AFTER all formal runs) ----------------
if [ "${STAGE13_SKIP_ANCHOR:-0}" != "1" ]; then
  for AP in "${ANCHOR_PAIRS[@]}"; do
    check_time_rail
    AD="$RUN_DIR/anchor_run_$AP"
    mkdir -p "$AD"
    if [ -f "$AD/armK.done" ]; then
      echo "  [anchor $AP arm K] already done (resume)"; continue
    fi
    if [ -f "$AD/armK.failed" ]; then
      warn "anchor $AP arm K: previous attempt voided by server-side error — replaying identical load"
      rm -f "$AD/armK.failed" "$AD/armK.jsonl"
    fi
    AIDX=91; [ "$AP" = "pair_3" ] && AIDX=93   # declared anchor run seeds: base+91 (pair_1), base+93 (pair_3)
    say "anchor run — $AP, arm K ($ANCHOR_ARM, descriptive only, never enters any CI)"
    RUN_SUBDIR="anchor_run_$AP"
    CUR_RUN="$AIDX"
    if [ "${STAGE13_SKIP_SERVER:-0}" != "1" ]; then
      start_server "K"
    fi
    set +e
    run_block "$AIDX" "K" "$AP"
    RC=$?
    set -e
    RUN_SUBDIR=""
    if [ "$RC" -eq 45 ]; then
      [ "${STAGE13_SKIP_SERVER:-0}" != "1" ] && stop_server || true
      die "anchor run $AP arm K voided by server-side error — incident recorded in $AD/armK.failed. Formal runs are unaffected; re-run to replay the anchor block."
    fi
    [ "$RC" -eq 0 ] || die "anchor block client failed (rc=$RC) — see stage.log"
    [ "${STAGE13_SKIP_SERVER:-0}" != "1" ] && stop_server || true
  done
fi

# ---------------- sealed verdict phase (runs only after all 10 runs complete) ----------------
MISSING=""
for i in $RUNS; do
  [ -f "$RUN_DIR/formal_run_$i/RUN_COMPLETE" ] || MISSING="$MISSING $i"
done
[ -z "$MISSING" ] || die "incomplete runs:$MISSING — re-run the nightly command to resume"

say "all $N_RUNS runs complete — computing the sealed dual verdict from raw archives"
set +e
run_verdict
RC_V=$?
set -e

if [ "$RC_V" -eq 0 ] || [ "$RC_V" -eq 2 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  V=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict_t.json'))['pilot004_verdict'])")
  say "stage 13 COMPLETE — PILOT 004 VERDICT: $V (see verdict_t.txt)"
  echo "  verify: bash stages/13-tuned-perf.sh --verify $RUN_DIR"
  if [ "${STAGE13_MOCK_BUILD:-0}" != "1" ]; then
    rm -rf "$CKPT_DIR" 2>/dev/null && echo "  candidate checkpoint deleted (hash anchor in checkpoint_perf.json)" || true
    [ -n "$ANCHOR_CKPT_DIR" ] && rm -rf "$ANCHOR_CKPT_DIR" 2>/dev/null && echo "  anchor checkpoint deleted (hash anchor in checkpoint_anchor.json)" || true
  fi
  exit "$RC_V"   # 0=PASS-complete, 2=scientific-FAIL-complete (frozen exit-code contract)
else
  echo "STAGE 13: verdict computation failed (rc=$RC_V) — no COMPLETE marker"
  exit 1
fi
