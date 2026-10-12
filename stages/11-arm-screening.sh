#!/usr/bin/env bash
# =============================================================================
# Pilot 004 — STAGE 11: ARM SCREENING (red-dot retry, cheap phase of 2)
#
# Pre-registered in PROTOCOL-LOCK v3.0 (frozen before execution). Question:
# on H100, does the lever space contain a configuration that holds quality
# within tolerance of the HARDWARE-LOCAL BF16 reference (gen_R, stage 10)
# while targeting a higher throughput floor than Pilot 003's full-attention
# exemption — measured on the Pilot 003 screening set, reused by hash?
#
# Two-phase anti-p-hacking design (frozen):
#   - This stage is the CHEAP phase. Screening conclusions are indicative.
#   - The winning arm gets ONE confirmation attempt on the frozen 150-item
#     set in stage 12. No second shot without a new addendum.
#
# Structure (frozen):
#   - Screening set: the Pilot 003 40-item set, reused by sha256
#     (d0b3da96…9b5ab) from the stage-10 anchor run; disjointness from the
#     frozen 150 was asserted at its birth and is re-asserted here.
#   - Reference arm R: BF16 defaults on H100 (generated in stage 10 —
#     hardware-local reference; no generation in this stage).
#   - Wave 1: 4 arms — b0-control (exact Pilot 002 stage-05 arm-B config,
#     vLLM dynamic FP8), b1-profile-exempt (H1: profile-driven minimal
#     exemption), b2-smooth-exempt (H1 + activation smoothing), b3-a4-kv
#     (H2: Pilot 003 winner + KV-cache FP8) — see arms-manifest.json.
#   - Sensitivity profiling (frozen method; the legitimacy source of H1):
#     per-module relative output MSE of FP8-E4M3 fake-quantized attention
#     projections vs BF16 over the 256 calibration texts (f7020a78…c8ab8);
#     exemption set = deterministic top-k UNION over-threshold selection.
#     The method is public; k and the threshold are gate-layer recipe
#     parameters (pod-only).
#   - Wave 2: 1 arm (b4-w2) composed by the deterministic rule
#     merge(top1, top2) from the wave-1 ranking of {b1, b2, b3}
#     (tie-break: overall delta, then arm_id).
#   - Screening judge: ONE external judge, frozen probe order (declared
#     below). Screening numbers are indicative; the confirm stage uses
#     the full panel.
#   - Winner selection (frozen): argmax clarity delta among non-control
#     arms; tie-break: overall delta, then fewer levers, then arm_id.
#   - Proceed rule (frozen): PROCEED iff winner clarity delta >= -0.05
#     (half-tolerance transfer margin, declared); otherwise
#     SCREENING-EXHAUSTED — a legitimate, publishable FAIL outcome.
#
# Recipe custody (three-layer disclosure policy): full lever recipes live
# ONLY in ~/pilot-env/arms-recipes.json on the pod (never committed). The
# public manifest carries sha256 per recipe; the run archive records the
# sha256 of every recipe actually executed. Time-delayed disclosure: the
# hash chain proves that a future public disclosure is identical to what
# ran today.
#
# Checkpoint custody: derived checkpoints are built on pod, hashed
# (full-tree sha256), used for generation, then DELETED (disk budget).
# The hash is the anchor; stage 12 rebuilds from the identical frozen
# recipe and discloses both hashes if a rebuild differs.
#
# Anchors (L1): Qwen2.5-14B-Instruct @ cf98f3b3…, vLLM 0.31.0, one H100 SXM
# 80GB (L3 hardware scope — Pilot 004 claims are H100-scoped), prefix
# caching OFF, temperature 0, natural stopping.
#
# Budget guards: MAX_SECONDS wall-clock rail; JUDGE_TOKEN_CAP judge token
# budget (cost figures never appear in public artifacts — 2026-10-10 rule).
#
# Verify entry: bash stages/11-arm-screening.sh --verify [run_dir]
# Recomputes the screening verdict from the archived logs only.
#
# Test hooks (sandbox only, never set in production):
#   STAGE11_OUT_DIR, STAGE11_SKIP_SERVER, STAGE11_SKIP_ANCHORS,
#   STAGE11_MOCK_BUILD, STAGE11_MOCK_PROFILE, STAGE11_SRC10_DIR,
#   PORT, OR_BASE_URL, KEY_FILE, MAX_SECONDS, JUDGE_TOKEN_CAP, RECIPES_FILE
# =============================================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot004}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_NAME="11-arm-screening"

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"                                   # L1 pinned
GPU_EXPECT="H100"
MAX_MODEL_LEN=32768
FROZEN_SHA="728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d"  # frozen 150 (disjointness re-assert)
MANIFEST_SHA="4eccbcb324b67282d07aaa4f535d8a2a1a8663e3774509b57e6aa4ddfd445362"   # arms-manifest.json (pinned at freeze)
SCREEN_SHA="d0b3da96251019d34006ade5fdb0017b3850770abeabc89cc8a6f16a29a9b5ab"  # Pilot 003 screening 40 (reused)
CALIB_TEXTS_SHA="f7020a784e8745c79ccfe4a8a810f1d05738ee0ae9eab9245e755cbc1aac8ab8"  # 256 calibration texts (reused)
N_SCREEN=40                                            # frozen
BLIND_SEED_SCR=20265001                                # frozen (Pilot 004 screening blind stream)
TOL=0.1                                                # frozen tolerance
PROCEED_MARGIN=0.05                                    # frozen: winner clarity delta >= -PROCEED_MARGIN
GEN_CONC=8                                             # serving concurrency (same craft as stage 05)
BOOT_SEED=20261012                                     # descriptive only, declared
BOOT_N=100000
MAX_SECONDS="${MAX_SECONDS:-28800}"                    # ~8 h rail (profiling + builds + gen + judge)
JUDGE_TOKEN_CAP="${JUDGE_TOKEN_CAP:-4000000}"          # judge token budget (no dollar figures in public artifacts)
KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
RECIPES_FILE="${RECIPES_FILE:-$HOME/pilot-env/arms-recipes.json}"
CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p004-ckpt}"        # build-and-delete workspace
PORT="${PORT:-8000}"                                   # env override is a test hook only

# Screening judge candidates (frozen probe order; reasoning disabled at
# generation per the Pilot 003 ADDENDUM-06 craft, empty content = unreachable).
SCREEN_JUDGE_CANDIDATES=(
    "deepseek/deepseek-chat-v3.1"
    "deepseek/deepseek-v3.1-terminus"
    "z-ai/glm-4.6"
)

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\n\033[1;31m[stage11][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

set_paths() {
  RUN_DIR="$1"
  SCREEN_JSONL="$RUN_DIR/screening_set.jsonl"
  CALIB_JSONL="$RUN_DIR/calibration_texts.jsonl"
  GEN_R_JSONL="$RUN_DIR/gen_R.jsonl"
  PROFILE_JSON="$CKPT_ROOT/profile.json"            # pod-local, NEVER pushed: per-module MSE ranking is gate-layer
                                                    # (ranking + public exempt-count ≈ the exemption set; sha only is public)
  PROFILE_REF="$RUN_DIR/profile_ref.json"           # public: profile sha256 + method text ONLY
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw_screen.jsonl"
  RECIPE_LOG="$RUN_DIR/recipes_executed.jsonl"      # public: hashes + lever class labels ONLY
  CKPT_LOG="$RUN_DIR/checkpoints.jsonl"             # public: checkpoint hashes ONLY
  LOCAL_RECIPE_LOG="$CKPT_ROOT/recipes-local.jsonl" # pod-local, NEVER pushed: full recipe bodies
  VERDICT_TXT="$RUN_DIR/verdict_s.txt"
  WINNER_JSON="$RUN_DIR/winner.json"
}

# ---------- screening verdict (recomputable from the archive alone) ----------
run_verdict() {
  RUN_DIR="$RUN_DIR" SCREEN_JSONL="$SCREEN_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
  RECIPE_LOG="$RECIPE_LOG" VERDICT_TXT="$VERDICT_TXT" WINNER_JSON="$WINNER_JSON" \
  N_SCREEN="$N_SCREEN" TOL="$TOL" PROCEED_MARGIN="$PROCEED_MARGIN" \
  BLIND_SEED_SCR="$BLIND_SEED_SCR" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
  MANIF="${MANIFEST:-}" GIT_REV="$GIT_REV" GEN_CONC="$GEN_CONC" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
SCREEN  = os.environ["SCREEN_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
RLOG    = os.environ["RECIPE_LOG"]
VERDICTF= os.environ["VERDICT_TXT"]
WINNERF = os.environ["WINNER_JSON"]
N_SCREEN= int(os.environ["N_SCREEN"])
TOL     = float(os.environ["TOL"])
MARGIN  = float(os.environ["PROCEED_MARGIN"])
BLSEED  = os.environ["BLIND_SEED_SCR"]
BSEED   = int(os.environ["BOOT_SEED"])
MANIF   = os.environ.get("MANIF", "")
BN      = int(os.environ["BOOT_N"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"
def blind(arm, rid):
    return hashlib.sha256(f"{BLSEED}|{arm}|{rid}".encode()).digest()[0] & 1 == 1

lines = ["STAGE 11 VERDICT — LEVER SCREENING (PILOT 004, phase 1 of 2: indicative)",
         f"tolerance={TOL}; proceed rule: winner clarity delta >= -{MARGIN} (declared transfer margin)",
         "screening conclusions are INDICATIVE — the winner gets ONE confirmation attempt in stage 12",
         f"generation: serving mode, temperature=0, concurrency {os.environ['GEN_CONC']}, natural stopping",
         f"blind: per (arm,item) sha256 bit, seed={BLSEED}; reference arm R = BF16 defaults", ""]
for name, p in [("screening_set.jsonl", SCREEN), ("gen_R.jsonl", os.path.join(RUN_DIR, "gen_R.jsonl")),
                ("judge_raw_screen.jsonl", JRAW)]:
    lines.append(f"  {name}: sha256={sha(p)}")
lines.append(f"scripts_rev={os.environ['GIT_REV']}")

screen = [json.loads(l) for l in open(SCREEN) if l.strip()]
rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
# one-row-per-(item, arm) invariant: an append-only log can carry duplicates after a
# killed-and-resumed or double-invoked run; the LAST row wins, completeness is counted
# on unique keys — never on physical line count.
if rows:
    _latest = {}
    for _r in rows: _latest[(_r["request_id"], _r["arm_id"])] = _r
    if len(_latest) != len(rows):
        print(f"  note: judge log carried {len(rows) - len(_latest)} duplicate row(s) — collapsed (last write wins)")
    rows = list(_latest.values())
arms = sorted({r["arm_id"] for r in rows},
              key=lambda a: min(i for i, r in enumerate(rows) if r["arm_id"] == a))
jmodels = sorted({r["judge_model"] for r in rows})
lines += ["", f"screening judge(s): {', '.join(jmodels) if jmodels else '(none)'}",
          f"arms with judged rows: {', '.join(arms) if arms else '(none)'}",
          f"judged rows: {len(rows)} / {N_SCREEN} per arm"]

per_arm = {}
for a in arms:
    rs = [r for r in rows if r["arm_id"] == a]
    if len(rs) < N_SCREEN:
        continue
    deltas_cl, deltas_all = [], []
    for r in rs:
        sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
        sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
        deltas_cl.append(sA["clarity"] - sR["clarity"])
        deltas_all.append(statistics.mean(sA[x] - sR[x] for x in AXES))
    per_arm[a] = dict(n=len(rs), clarity=statistics.mean(deltas_cl), overall=statistics.mean(deltas_all))

lines += ["", "[per-arm screening deltas vs BF16 reference (40 items, 10-pt scale)]",
          f"  {'arm':22s} {'clarity':>8s} {'overall':>8s}"]
for a in sorted(per_arm):
    lines.append(f"  {a:22s} {per_arm[a]['clarity']:+8.3f} {per_arm[a]['overall']:+8.3f}")

non_control = sorted(a for a in per_arm if a != "b0-control")
if not non_control:
    lines += ["", "REFUSED: no fully-judged non-control arm — screening incomplete; re-run to resume."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

import numpy as np
# descriptive CI for the winner only, declared seed
rank = sorted(non_control, key=lambda a: (-per_arm[a]["clarity"], -per_arm[a]["overall"], a))
winner = rank[0]
wcl = per_arm[winner]["clarity"]

# lever count for the record (from executed recipes log if present)
nlev = None
if os.path.exists(RLOG):
    for l in open(RLOG):
        r = json.loads(l)
        if r.get("arm_id") == winner:
            nlev = len(r.get("levers", [])); break

wd = []
for r in rows:
    if r["arm_id"] != winner: continue
    sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
    sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
    wd.append(sA["clarity"] - sR["clarity"])
if wd:
    rng = np.random.default_rng(BSEED)
    means = rng.choice(np.array(wd), size=(BN, len(wd)), replace=True).mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
else:
    lo = hi = float("nan")

ctrl = per_arm.get("b0-control")
lines += ["",
    f"[control] b0-control (= exact Pilot 002 stage-05 arm-B config) clarity delta on screening set: "
    f"{ctrl['clarity']:+.3f}" if ctrl else "[control] b0-control not fully judged",
    "",
    f"[selection] winner = {winner} (clarity {wcl:+.3f}, overall {per_arm[winner]['overall']:+.3f}"
    + (f", levers={nlev}" if nlev is not None else "") + ")",
    f"[descriptive] winner clarity 95% bootstrap CI: [{lo:+.3f}, {hi:+.3f}] (seed={BSEED}, n={len(wd)})",
    ""]
outcome = "PROCEED" if wcl >= -MARGIN else "SCREENING-EXHAUSTED"
if outcome == "PROCEED":
    lines += [f"OUTCOME: PROCEED — {winner} advances to the single-shot confirmation (stage 12).",
              "discipline: stage 12 is the ONLY confirmation attempt; a miss is a published FAIL."]
else:
    lines += [f"OUTCOME: SCREENING-EXHAUSTED — no arm reached the declared margin (-{MARGIN}).",
              "This is a legitimate, publishable FAIL: the screened lever space is insufficient",
              "on this model x workload. All arm data above is the evidence."]
lines += ["", "This file is reproducible from the archived logs alone: bash stages/11-arm-screening.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")

if outcome == "PROCEED":
    # recipe hash custody: wave-1 winners resolve from the FROZEN manifest
    # (independent of build-order bookkeeping); wave-2 winners from the
    # public executed-recipes log written by compose_wave2.
    wsha = None
    if os.path.exists(MANIF):
        for a in json.load(open(MANIF))["arms"]:
            if a.get("arm_id") == winner:
                s = a.get("recipe_sha256", "")
                if s and not s.startswith("composed-at-runtime"):
                    wsha = s
                break
    if wsha is None and os.path.exists(RLOG):
        for l in open(RLOG):
            r = json.loads(l)
            if r.get("arm_id") == winner:
                wsha = r.get("recipe_sha256"); break
    if wsha is None:
        print(f"FATAL: cannot resolve recipe_sha256 for winner {winner} — custody chain incomplete")
        raise SystemExit(1)
    json.dump(dict(arm_id=winner, screening_clarity_delta=wcl,
                   screening_overall_delta=per_arm[winner]["overall"],
                   levers=nlev, recipe_sha256=wsha, scripts_rev=os.environ["GIT_REV"]),
              open(WINNERF, "w"), indent=2, sort_keys=True)
    print(f"winner.json written: {winner} (recipe_sha256={str(wsha)[:16]}…)")
print("\n".join(lines))
raise SystemExit(0 if outcome == "PROCEED" else 2)
PY
}

# ---------- frozen manifest resolution (needed by BOTH --verify and main flow;
# winner.json resolves wave-1 recipe hashes from the frozen manifest) ----------
MANIFEST="$SCRIPTS_DIR/arms-manifest.json"
[ -f "$MANIFEST" ] || MANIFEST="$(dirname "$(readlink -f "$0")")/../arms-manifest.json"
[ -f "$MANIFEST" ] || die "arms-manifest.json not found (expected at repo root)"
ACTUAL_MSHA=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
[ "$ACTUAL_MSHA" = "$MANIFEST_SHA" ] || die "arms-manifest.json hash mismatch: $ACTUAL_MSHA != $MANIFEST_SHA — manifest is frozen by PROTOCOL-LOCK v3.0"

# ---------- --verify ----------
# Recompute the screening verdict from the archived logs and byte-compare.
# Declared normalization (machine-local provenance only): scripts_rev=...
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  if [ -z "$D" ]; then D="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$D" ] && [ -f "$D/verdict_s.txt" ] || { echo "VERIFY: usage: --verify <run_dir> (no screening verdict archive found)"; exit 1; }
  note "verify: recomputing screening verdict from archived logs in $D (no network, no GPU)"
  GIT_REV="verify"
  TMPD="$(mktemp -d)"
  cp "$D"/screening_set.jsonl "$D"/gen_R.jsonl "$D"/judge_raw_screen.jsonl "$TMPD/" 2>/dev/null || true
  [ -f "$D/recipes_executed.jsonl" ] && cp "$D/recipes_executed.jsonl" "$TMPD/" || true
  set_paths "$TMPD"
  set +e
  run_verdict > /dev/null
  set -e
  python3 - "$D" "$TMPD" <<'PY'
import re, sys
a, b = sys.argv[1], sys.argv[2]
def norm(t): return re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
ta, tb = norm(open(a + "/verdict_s.txt").read()), norm(open(b + "/verdict_s.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_s.txt byte-identical (declared provenance normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------- run bookkeeping: resume-or-create; COMPLETE re-entry guard ----------
note "0. run bookkeeping"
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)
if [ -n "${STAGE11_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE11_OUT_DIR"; mkdir -p "$RUN_DIR"
else
  LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
    echo "STAGE 11 already COMPLETE: $LATEST"
    echo "verdict: $LATEST/verdict_s.txt  (to recompute: bash stages/11-arm-screening.sh --verify)"
    exit 0
  fi
  RUN_DIR=""
  for cand in $(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null); do
    if [ ! -f "$cand/COMPLETE" ]; then RUN_DIR="$cand"; echo "resuming incomplete run dir: $RUN_DIR"; break; fi
  done
  if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1"
    SUFFIX=2
    while [ -e "$RUN_DIR" ]; do RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1-r${SUFFIX}"; SUFFIX=$((SUFFIX+1)); done
    mkdir -p "$RUN_DIR"
    echo "new run dir: $RUN_DIR"
  fi
fi
set_paths "$RUN_DIR"

# ---------- preflight ----------
note "1. time / host / GPU / engine anchors (L1)"
date -u
hostname || true
echo "scripts_rev=$GIT_REV"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true
if [ "${STAGE11_SKIP_SERVER:-0}" != "1" ]; then
  python3 - <<PY
import sys
try:
    import vllm
    assert vllm.__version__ == "$VLLM_PINNED", f"vLLM {vllm.__version__} != pinned $VLLM_PINNED (L1)"
    print("vllm:", vllm.__version__, "(pinned OK)")
except ImportError:
    sys.exit("No module named 'vllm' — install vllm==$VLLM_PINNED first (L1 pin)")
PY
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  [[ "$GPU_NAME" == *"$GPU_EXPECT"* ]] || die "expected $GPU_EXPECT, found '$GPU_NAME' (hardware boundary, L3)"
  echo "gpu: $GPU_NAME"
fi

# manifest + recipes custody check (three-layer disclosure: hashes public, bodies private)
# (manifest path + hash already asserted above, before the --verify branch)
echo "arms-manifest.json: sha256 verified ($MANIFEST_SHA)"
[ -f "$RECIPES_FILE" ] || die "private recipes file missing: $RECIPES_FILE — place it on the pod (chmod 600) before running; it is never committed"
PERMS=$(stat -c %a "$RECIPES_FILE" 2>/dev/null || echo "?")
[ "$PERMS" = "600" ] || echo "WARNING: $RECIPES_FILE permissions are $PERMS (expected 600)"

[ -f "$KEY_FILE" ] || die "judge key not found at $KEY_FILE (same pod-side pattern as Pilot 002)"
python3 -c "import httpx" 2>/dev/null || pip install -q httpx
echo "banner: PILOT 004 STAGE 11 — LEVER SCREENING (indicative phase; single-shot confirm is stage 12)"
START_TS=$(date +%s)

# ---------- phase 2: anchors from stage 10 (screening set / calibration texts / gen_R, sha-pinned) ----------
note "2. stage-10 anchors (screening set d0b3da96…, calibration texts f7020a78…, gen_R H100)"

SRC10_DIR="${STAGE11_SRC10_DIR:-}"
if [ -z "$SRC10_DIR" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/10-preflight-calib/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && [ -f "$d/anchors.json" ] && SRC10_DIR="$d" && break
  done
fi
[ -n "$SRC10_DIR" ] || die "no COMPLETE stage-10 run with anchors.json found — run stage 10 first"
echo "stage-10 anchor run: $SRC10_DIR"

copy_anchor() {   # $1 = filename, $2 = expected sha (empty = take sha from stage-10 anchors.json)
  local f="$1" want="$2"
  if [ "${STAGE11_SKIP_ANCHORS:-0}" = "1" ] && [ -n "$want" ]; then
    want=""   # sandbox only: fixed-sha asserts bypassed; stage-10 anchors.json pinning still applies
  fi
  if [ -z "$want" ]; then
    want="$(ANCHORS="$SRC10_DIR/anchors.json" F="$f" python3 -c "import json,os; print(json.load(open(os.environ['ANCHORS']))['files'][os.environ['F']])")"
  fi
  if [ -f "$RUN_DIR/$f" ] && [ "$(sha256sum "$RUN_DIR/$f" | cut -d' ' -f1)" = "$want" ]; then
    echo "  $f: already anchored (sha OK) — resume skip"; return 0
  fi
  [ -f "$SRC10_DIR/$f" ] || die "stage-10 anchor missing: $SRC10_DIR/$f"
  local got; got="$(sha256sum "$SRC10_DIR/$f" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "$f sha256 mismatch: $got != $want — stage-10 anchor chain broken, escalate"
  cp "$SRC10_DIR/$f" "$RUN_DIR/$f"
  echo "  $f anchored: $want"
}
copy_anchor screening_set.jsonl "$SCREEN_SHA"
copy_anchor calibration_texts.jsonl "$CALIB_TEXTS_SHA"
copy_anchor frozen_set.jsonl "$FROZEN_SHA"
copy_anchor gen_R.jsonl ""        # sha pinned via stage-10 anchors.json (hardware-local, generated there)

# disjointness re-assert (hard gate): the screening set must not touch the frozen 150
SCREEN_JSONL="$SCREEN_JSONL" FROZEN_JSONL="$RUN_DIR/frozen_set.jsonl" python3 - <<'PY'
import hashlib, json, os, sys
frozen = {hashlib.sha256(json.loads(l)["prompt"].encode()).hexdigest()
          for l in open(os.environ["FROZEN_JSONL"]) if l.strip()}
overlap = sum(1 for l in open(os.environ["SCREEN_JSONL"])
              if l.strip() and hashlib.sha256(json.loads(l)["prompt"].encode()).hexdigest() in frozen)
if overlap:
    print(f"FATAL: screening set overlaps the frozen 150 on {overlap} prompts"); sys.exit(1)
print("disjointness re-assert: 0 collisions with the frozen 150 — OK")
PY

# ---------- phase 3: sensitivity profiling (frozen method; the legitimacy source of H1) ----------
note "3. sensitivity profiling (per-module relative MSE, FP8-E4M3 fake-quant vs BF16, 256 calibration texts)"
if [ -f "$PROFILE_JSON" ]; then
  echo "profile.json already present — resume skip (sha256=$(sha256sum "$PROFILE_JSON" | cut -c1-16)…)"
elif [ "${STAGE11_MOCK_PROFILE:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE11_MOCK_PROFILE=1 — synthetic profile (sandbox only)"
  python3 - "$PROFILE_JSON" "$CALIB_JSONL" <<'PY'
import hashlib, json, os, sys
mods = [f"model.layers.{i}.self_attn.{p}_proj" for i in range(40) for p in ("q", "k", "v", "o")]
prof = [{"module": m, "mse_rel": (hash(m) % 1000) / 1000.0 * 0.05} for m in mods]
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
ct_sha = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest() if os.path.exists(sys.argv[2]) else None
json.dump({"method": "per-module relative output MSE of FP8_E4M3 fake-quantized attention projections vs BF16",
           "calibration_texts_sha256": ct_sha,
           "mock": True, "modules": prof}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
else
  check_disk() { local f; f=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9'); [ "${f:-0}" -ge 60 ] || die "disk headroom < 60GB for profiling (BF16 weights)"; }
  check_disk
  PROFILE_JSON="$PROFILE_JSON" CALIB_JSONL="$CALIB_JSONL" MODEL="$MODEL" MODEL_REV="$MODEL_REV"   MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, re, time
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

PROFILE = os.environ["PROFILE_JSON"]
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_JSONL"])]
assert len(calib) == 256, "calibration texts must be the 256 anchored samples"
MAX_TOK = 1024          # frozen in protocol (profiling truncation)
RESERVOIR = 4096        # frozen: max captured rows per module
RES_SEED = 20265002     # frozen reservoir stream
SCOPE = re.compile(r"^model\.layers\.\d+\.self_attn\.(q_proj|k_proj|v_proj|o_proj)$")

tok = AutoTokenizer.from_pretrained(os.environ["MODEL"], revision=os.environ["MODEL_REV"])
print("loading BF16 model for profiling (one forward pass over 256 texts)…", flush=True)
model = AutoModelForCausalLM.from_pretrained(
    os.environ["MODEL"], revision=os.environ["MODEL_REV"],
    torch_dtype=torch.bfloat16, device_map="cuda")
model.eval()

rng = torch.Generator().manual_seed(RES_SEED)
caps = {}    # module name -> CPU reservoir of input rows
counts = {}
def mk_hook(name):
    def hook(mod, args):
        x = args[0].detach()
        rows = x.reshape(-1, x.shape[-1])
        n = rows.shape[0]
        counts[name] = counts.get(name, 0) + n
        if name not in caps:
            take = min(RESERVOIR, n)
            idx = torch.randperm(n, generator=rng)[:take]
            caps[name] = rows[idx].to(torch.float32).cpu()
        else:
            cur = caps[name].shape[0]
            if cur < RESERVOIR:
                take = min(RESERVOIR - cur, n)
                idx = torch.randperm(n, generator=rng)[:take]
                caps[name] = torch.cat([caps[name], rows[idx].to(torch.float32).cpu()], 0)
    return hook

handles = []
for name, mod in model.named_modules():
    if SCOPE.match(name) and isinstance(mod, torch.nn.Linear):
        handles.append(mod.register_forward_pre_hook(mk_hook(name)))
print(f"hooks on {len(handles)} attention projections", flush=True)
assert len(handles) > 0, "no attention projections matched the profiling scope"

B = 8
with torch.no_grad():
    for i in range(0, len(calib), B):
        if time.time() - int(os.environ["START_TS"]) > int(os.environ["MAX_SECONDS"]):
            raise SystemExit("time rail during profiling — re-run to resume (profile.json not yet written)")
        batch = tok(calib[i:i+B], return_tensors="pt", padding=True, truncation=True,
                    max_length=MAX_TOK).to("cuda")
        model(**batch)
        if i % 64 == 0:
            print(f"  profiled {i}/{len(calib)} texts", flush=True)
for h in handles: h.remove()

prof = []
for name, mod in model.named_modules():
    if name not in caps:
        continue
    W = mod.weight.detach().to(torch.float32)
    amax = W.abs().max().clamp_min(1e-12)
    scale = amax / 448.0
    Wq = (torch.clamp(W / scale, -448.0, 448.0).to(torch.float8_e4m3fn).to(torch.float32)) * scale
    X = caps[name]                     # (rows, in_features), float32 CPU
    D = (W - Wq)
    num = den = 0.0
    CH = 512
    for j in range(0, X.shape[0], CH):
        xb = X[j:j+CH].cuda()
        num += float(((D.cuda() @ xb.t()) ** 2).sum())
        den += float(((W.cuda() @ xb.t()) ** 2).sum())
        del xb
    prof.append({"module": name, "mse_rel": num / max(den, 1e-20), "rows_seen": counts[name]})
    torch.cuda.empty_cache()

prof.sort(key=lambda r: (-r["mse_rel"], r["module"]))
doc = {"method": "per-module relative output MSE of FP8_E4M3 fake-quantized attention projections vs BF16 (per-tensor symmetric scale=amax/448)",
       "scope": SCOPE.pattern, "calibration_texts_sha256": hashlib.sha256(open(os.environ["CALIB_JSONL"], "rb").read()).hexdigest(),
       "n_texts": len(calib), "max_tokens_per_text": MAX_TOK, "reservoir_rows": RESERVOIR, "reservoir_seed": RES_SEED,
       "modules": prof}
os.makedirs(os.path.dirname(PROFILE), exist_ok=True)
json.dump(doc, open(PROFILE, "w"), indent=2, sort_keys=True)
print(f"profile.json written (pod-local, gate-layer): {len(prof)} modules, "
      f"max mse_rel={prof[0]['mse_rel']:.6f} ({prof[0]['module']})", flush=True)
PY
fi

# public side carries the sha ONLY — the ranking content never leaves the pod
if [ -f "$PROFILE_JSON" ]; then
  python3 - "$PROFILE_JSON" "$PROFILE_REF" <<'PY'
import hashlib, json, sys
src, ref = sys.argv[1], sys.argv[2]
d = json.load(open(src))
json.dump({"profile_sha256": hashlib.sha256(open(src, "rb").read()).hexdigest(),
           "method": d.get("method"),
           "calibration_texts_sha256": d.get("calibration_texts_sha256"),
           "note": "profile content is gate-layer (pod-local, backed up to the network volume); this sha pins it into the custody chain"},
          open(ref, "w"), indent=2, sort_keys=True)
print("profile_ref.json written (sha-only public reference)")
PY
fi

# deterministic exemption selection + b1/b2 recipe composition (gate-layer k/threshold)
note "3b. compose b1/b2 recipes from profile + gate-layer parameters"
if grep -q '"arm_id": "b1-profile-exempt"' "$RECIPE_LOG" 2>/dev/null && grep -q '"arm_id": "b2-smooth-exempt"' "$RECIPE_LOG" 2>/dev/null; then
  echo "b1/b2 recipes already composed — resume skip"
else
  PROFILE_JSON="$PROFILE_JSON" RECIPES_FILE="$RECIPES_FILE"   RECIPE_LOG="$RECIPE_LOG" LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" python3 - <<'PY'
import hashlib, json, os, statistics, sys
prof = json.load(open(os.environ["PROFILE_JSON"]))["modules"]
doc = json.load(open(os.environ["RECIPES_FILE"]))
P = doc.get("profiling") or sys.exit("gate-layer profiling parameters missing from arms-recipes.json")
k, mult = int(P["top_k"]), float(P["theta_mult"])
mses = [r["mse_rel"] for r in prof]
med = statistics.median(mses)
theta = mult * med
topk = {r["module"] for r in prof[:k]}
over = {r["module"] for r in prof if r["mse_rel"] > theta}
exempt = sorted(topk | over)
print(f"selection: top_k={k}, theta={theta:.6f} ({mult}x median {med:.6f}); exempt {len(exempt)} modules "
      f"(top-k {len(topk)} + over-threshold {len(over)} - overlap {len(topk & over)})")
if not exempt:
    sys.exit("FATAL: exemption set empty — H1 has no signal; owner decision required")
ignore = ["lm_head", "embed_tokens"] + exempt
calib = {"max_seq_len": 2048, "n_samples": 256, "seed": 20261015}
b1 = {"arm_id": "b1-profile-exempt", "builder": "llmcompressor-oneshot",
      "levers": ["profile-driven-minimal-exemption:attention"],
      "quantization": {"ignore": ignore, "scheme": "FP8_DYNAMIC", "targets": "Linear"},
      "calibration": calib, "serve_extra": "--quantization compressed-tensors", "uses_base_model": False}
b2 = {"arm_id": "b2-smooth-exempt", "builder": "llmcompressor-oneshot",
      "levers": ["activation-smoothing", "profile-driven-minimal-exemption:attention"],
      "quantization": {"ignore": ignore, "scheme": "FP8_DYNAMIC", "targets": "Linear"},
      "smoothing": {"mappings": "qwen2.5-default", "strength": float(P["b2_smoothing_strength"])},
      "calibration": calib, "serve_extra": "--quantization compressed-tensors", "uses_base_model": False}
def canon(r): return hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
os.makedirs(os.path.dirname(os.environ["LOCAL_RECIPE_LOG"]), exist_ok=True)
for r in (b1, b2):
    sha = canon(r)
    with open(os.environ["RECIPE_LOG"], "a") as f:   # public: hash + labels ONLY
        f.write(json.dumps({"arm_id": r["arm_id"], "composed_from": ["profile.json", "gate-layer profiling params"],
                            "levers": r["levers"], "recipe_sha256": sha,
                            "exempted_modules": len(exempt)}, sort_keys=True) + "\n")
    with open(os.environ["LOCAL_RECIPE_LOG"], "a") as f:   # pod-local body, never pushed
        f.write(json.dumps({"arm_id": r["arm_id"], "recipe": r, "recipe_sha256": sha}, sort_keys=True) + "\n")
    print(f"  {r['arm_id']}: composed, recipe_sha256={sha[:16]}…")
PY
fi

# ---------- recipe machinery: verify custody, build checkpoints ----------
# Prints the recipe for ARM_ID to stdout as canonical JSON (used by the builder).
get_recipe() {   # $1 = arm_id
  RECIPES_FILE="$RECIPES_FILE" MANIFEST_SHA="$MANIFEST_SHA" ARM_ID="$1" python3 - <<'PY'
import hashlib, json, os, sys
doc = json.load(open(os.environ["RECIPES_FILE"]))
arm = os.environ["ARM_ID"]
recs = doc["recipes"]
if arm in recs:
    r = recs[arm]
else:
    # wave-2 slot: recipe is composed at runtime and kept in the POD-LOCAL
    # recipe log (never pushed); reading it back keeps resume deterministic
    r = None
    rlog = os.environ.get("LOCAL_RECIPE_LOG", "")
    if rlog and os.path.exists(rlog):
        for l in open(rlog):      # append-only log: the LAST match is the current composition
            e = json.loads(l)
            if e.get("arm_id") == arm:
                r = e.get("recipe")
    if r is None:
        sys.exit(f"recipe for {arm} not found in the pod-local log (wave-2 recipes are composed after wave-1 judging)")
sha = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
print(json.dumps(dict(arm_id=arm, recipe=r, recipe_sha256=sha)))
PY
}

# build_checkpoint ARM_ID → builds/validates the ckpt at deterministic $CKPT_ROOT/$arm.
# Prints NOTHING to stdout: builder libraries (llmcompressor loguru) log to stdout,
# so this function must NEVER be called inside $() — callers construct the path.
# No-op for base-model arms; reuse path returns early when custody log + dir agree.
build_checkpoint() {   # $1 = arm_id
  local arm="$1"
  local rjson; rjson="$(LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" get_recipe "$arm")" || die "cannot resolve recipe for $arm"
  local uses_base; uses_base="$(printf '%s' "$rjson" | python3 -c "import json,sys; print(json.load(sys.stdin)['recipe']['uses_base_model'])")"
  if [ "$uses_base" = "True" ]; then return 0; fi
  local cdir="$CKPT_ROOT/$arm"
  if [ -f "$CKPT_LOG" ] && grep -q "\"arm_id\": \"$arm\"" "$CKPT_LOG" 2>/dev/null && [ -d "$cdir" ]; then
    echo "checkpoint for $arm already built — reuse: $cdir" >&2; return 0
  fi
  if [ "${STAGE11_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$cdir"; echo '{"mock": true}' > "$cdir/config.json"
    echo "TEST HOOK: mock checkpoint for $arm at $cdir" >&2; return 0
  fi
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${FREE_GB:-0}" -ge 50 ] || die "disk headroom < 50GB for checkpoint build (14B fp8 ckpt ≈ 16GB on top of base weights)"
  note "building checkpoint for $arm (llmcompressor oneshot; builder version is provenance — the measured artifact is the checkpoint hash)" >&2
  RJSON="$rjson" CKPT_DIR="$cdir" CALIB_JSONL="$CALIB_JSONL" MODEL="$MODEL" MODEL_REV="$MODEL_REV" \
  RECIPE_LOG="$RECIPE_LOG" CKPT_LOG="$CKPT_LOG" LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" python3 - <<'PY'
import hashlib, json, os, time
spec = json.loads(os.environ["RJSON"])
arm, recipe = spec["arm_id"], spec["recipe"]
cdir = os.environ["CKPT_DIR"]
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_JSONL"])]
from datasets import Dataset as _HFDS
def _hfds_from_texts(texts):
    return _HFDS.from_list([{"text": t} for t in texts])

try:
    import llmcompressor
    from llmcompressor import oneshot
    from llmcompressor.modifiers.quantization import QuantizationModifier
    ver = llmcompressor.__version__
except ImportError:
    raise SystemExit("llmcompressor not installed — install it on the pod (pip install llmcompressor); builder version is recorded as provenance")
mods = []
if "smoothing" in recipe:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    s = recipe["smoothing"]
    mods.append(SmoothQuantModifier(smoothing_strength=s["strength"]))
q = recipe["quantization"]
q_kwargs = dict(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"])
if "kv_cache_scheme" in recipe:
    # b3-class arms: calibrated FP8 KV cache (llmcompressor 0.12.0 QuantizationModifier
    # accepts kv_cache_scheme as QuantizationArgs — verified against the wheel source)
    from compressed_tensors.quantization import QuantizationArgs
    q_kwargs["kv_cache_scheme"] = QuantizationArgs(**recipe["kv_cache_scheme"])
mods.append(QuantizationModifier(**q_kwargs))
t0 = time.time()
oneshot(model=os.environ["MODEL"], model_revision=os.environ["MODEL_REV"],
        dataset=_hfds_from_texts(calib), recipe=mods,
        output_dir=cdir,
        num_calibration_samples=recipe["calibration"]["n_samples"],
        max_seq_length=recipe["calibration"]["max_seq_len"])
def tree_sha(root):
    h = hashlib.sha256()
    for dp, _, fns in sorted(os.walk(root)):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            h.update(rel.encode())
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
    return h.hexdigest()
csha = tree_sha(cdir)
# custody split (three-layer disclosure): the public archive records hashes
# and lever class labels ONLY; the full recipe body stays pod-local.
public = dict(arm_id=arm, levers=recipe.get("levers", []),
              recipe_sha256=spec["recipe_sha256"], llmcompressor_version=ver,
              checkpoint_sha256=csha, build_seconds=round(time.time() - t0, 1),
              ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
for path in (os.environ["RECIPE_LOG"], os.environ["CKPT_LOG"]):
    with open(path, "a") as f:
        f.write(json.dumps(public, sort_keys=True) + "\n")
os.makedirs(os.path.dirname(os.environ["LOCAL_RECIPE_LOG"]), exist_ok=True)
with open(os.environ["LOCAL_RECIPE_LOG"], "a") as f:
    f.write(json.dumps(dict(public, recipe=recipe), sort_keys=True) + "\n")
import sys
print(f"checkpoint built: {arm} sha256={csha[:16]}… llmcompressor={ver} ({public['build_seconds']}s)", file=sys.stderr)
PY
  if [ ! -f "$cdir/config.json" ] || ! ls "$cdir"/*.safetensors >/dev/null 2>&1; then
    echo "checkpoint incomplete for $arm: $cdir (need config.json + at least one .safetensors shard)" >&2; return 1
  fi
  echo "checkpoint ready: $cdir" >&2
}

# ---------- server lifecycle (same craft as stage 05) ----------
start_server() {   # $1 = arm label, $2 = model path, $3 = extra args
  local arm="$1" mpath="$2" extra="$3"
  local slog="$RUN_DIR/server_${arm}.log"
  echo "starting server for $arm ($mpath $extra; prefix caching OFF)"
  # shellcheck disable=SC2086
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$mpath" $([ "$mpath" = "$MODEL" ] && echo --revision "$MODEL_REV") \
    --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
    $extra --port "$PORT" > "$slog" 2>&1 &
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "server process died — see $slog"; fi
  done
  echo "server for $arm healthy after ${waited}s"
  echo "server_argv: vllm serve $mpath $([ "$mpath" = "$MODEL" ] && echo --revision $MODEL_REV) --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN $extra --port $PORT" \
    | sed 's/  */ /g' > "$RUN_DIR/server_argv_${arm}.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------- generation (serving mode, natural stopping; same craft as stage 05) ----------
generate_arm() {   # $1 = arm label, $2 = model path, $3 = extra args, $4 = out jsonl
  local arm="$1" mpath="$2" extra="$3" gen_jsonl="$4"
  note "generation: $arm (screening set, concurrency $GEN_CONC)"
  if [ "$({ [ -f "$gen_jsonl" ] && wc -l < "$gen_jsonl"; } 2>/dev/null || echo 0)" -ge "$N_SCREEN" ]; then
    echo "  $arm: already generated ($N_SCREEN rows) — resume skip"; return 0
  fi
  if [ "${STAGE11_SKIP_SERVER:-0}" != "1" ]; then
    start_server "$arm" "$mpath" "$extra"
    trap stop_server EXIT
  else
    echo "STAGE11_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
  fi
  SCREEN_JSONL="$SCREEN_JSONL" GEN_JSONL="$gen_jsonl" ARM="$arm" \
  MODEL="$mpath" PORT="$PORT" GEN_CONC="$GEN_CONC" \
  MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import asyncio, datetime, hashlib, json, os, time
import httpx

MODEL  = os.environ["MODEL"]; SCREEN = os.environ["SCREEN_JSONL"]
GEN    = os.environ["GEN_JSONL"]; ARM = os.environ["ARM"]
PORT   = os.environ["PORT"]; CONC = int(os.environ["GEN_CONC"])
MAX_SEC= int(os.environ["MAX_SECONDS"]); T0 = int(os.environ["START_TS"])
REQ_TO = 900.0

items = [json.loads(l) for l in open(SCREEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in items if r["request_id"] not in done]
print(f"{ARM}: {len(done)} already generated, {len(todo)} to go", flush=True)
if not todo:
    raise SystemExit(0)

async def main():
    gate = asyncio.Semaphore(CONC)
    lock = asyncio.Lock()
    n_done = 0
    async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{PORT}",
                                 timeout=httpx.Timeout(REQ_TO, connect=30.0)) as client:
        async def one(rec):
            nonlocal n_done
            async with gate:
                body = dict(model=MODEL, prompt=rec["prompt"],
                            temperature=0, max_tokens=rec["max_tokens"])
                t0 = time.time()
                r = await client.post("/v1/completions", json=body)
                r.raise_for_status()
                wall = time.time() - t0
                resp = r.json()
                text = resp["choices"][0]["text"]
                usage = resp.get("usage", {})
                row = dict(request_id=rec["request_id"], arm=ARM,
                           form=rec["form"], tier_target=rec["tier_target"],
                           max_tokens=rec["max_tokens"],
                           prompt_tokens=usage.get("prompt_tokens", 0),
                           output_tokens=usage.get("completion_tokens", 0),
                           wall_s=round(wall, 3),
                           output_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                           output_text=text, model=MODEL,
                           scripts_rev=os.environ["GIT_REV"],
                           ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                async with lock:
                    with open(GEN, "a") as fg:
                        fg.write(json.dumps(row, sort_keys=True) + "\n")
                    n_done += 1
                    if n_done % 10 == 0 or n_done == 1:
                        print(f"  {ARM}: {len(done)+n_done}/{len(items)} "
                              f"(last: {rec['request_id']}, {row['output_tokens']} tok, {wall:.1f}s)", flush=True)
        await asyncio.gather(*(one(rec) for rec in todo))

asyncio.run(main())
print(f"{ARM} generation phase done", flush=True)
PY
  [ "${STAGE11_SKIP_SERVER:-0}" != "1" ] && stop_server || true
}

# ---------- blind judging on the screening set (single screening judge) ----------
judge_arms() {   # $@ = arm labels to judge (R is the reference, never judged)
  local arms="$*"
  SCREEN_JSONL="$SCREEN_JSONL" GEN_R_JSONL="$GEN_R_JSONL" RUN_DIR="$RUN_DIR" \
  JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" BLIND_SEED_SCR="$BLIND_SEED_SCR" \
  KEY_FILE="$KEY_FILE" JUDGE_TOKEN_CAP="$JUDGE_TOKEN_CAP" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
  OR_BASE_URL="${OR_BASE_URL:-https://openrouter.ai/api/v1}" GIT_REV="$GIT_REV" \
  ARMS="$arms" N_SCREEN="$N_SCREEN" \
  SCREEN_JUDGE_CANDIDATES_STR="$(printf '%s\n' "${SCREEN_JUDGE_CANDIDATES[@]}")" python3 - <<'PY'
import hashlib, json, os, time, datetime
import urllib.request, urllib.error

SCREEN  = os.environ["SCREEN_JSONL"]
GENR    = os.environ["GEN_R_JSONL"]
RUN_DIR = os.environ["RUN_DIR"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
BLSEED  = os.environ["BLIND_SEED_SCR"]
KEYF    = os.environ["KEY_FILE"]
TOKEN_CAP = int(os.environ["JUDGE_TOKEN_CAP"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
ORBASE  = os.environ["OR_BASE_URL"].rstrip("/")
ARMS    = os.environ["ARMS"].split()
AXES    = ["correctness", "instruction_following", "clarity"]

CANDIDATES = [l.strip() for l in os.environ["SCREEN_JUDGE_CANDIDATES_STR"].splitlines() if l.strip()]

KEY = open(KEYF).read().strip()
if not KEY.startswith("sk-or-") and "openrouter.ai" in ORBASE:
    print("REFUSED: key file does not look like an OpenRouter key"); raise SystemExit(1)

def call_api(model, messages, max_tokens, timeout=120):
    # ADDENDUM-06 craft (Pilot 003), now the default: reasoning disabled at
    # generation (enabled:false — zero-cost on non-reasoning judges, and the
    # only form that works with reasoning-type judges); null content = error
    body = json.dumps(dict(model=model, messages=messages, temperature=0,
                           max_tokens=max_tokens,
                           reasoning={"enabled": False})).encode()
    req = urllib.request.Request(
        f"{ORBASE}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/effiq/pilot004",
                 "X-Title": "effiq-pilot004-lever-screening"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# screening judge: probe in frozen order; the selection is persisted and sticky
JFILE = os.path.join(RUN_DIR, "screening_judge.txt")
judge_model = None
for cand in CANDIDATES:
    try:
        resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
        _txt = resp["choices"][0]["message"]["content"]
        if not _txt or not str(_txt).strip():
            raise ValueError("empty probe content")
        judge_model = cand
        print(f"screening judge reachable: {cand}")
        break
    except Exception as e:
        print(f"screening judge candidate {cand}: unavailable ({type(e).__name__}: {e})")
if judge_model is None:
    print("REFUSED: no screening judge reachable — check key balance/region; nothing judged.")
    raise SystemExit(1)
if os.path.exists(JFILE):
    prev = open(JFILE).read().strip()
    if prev != judge_model:
        print(f"REFUSED: previously selected screening judge {prev} is not the reachable one now ({judge_model}) — owner decision required")
        raise SystemExit(1)
else:
    open(JFILE, "w").write(judge_model + "\n")
    print(f"screening judge selected and pinned: {judge_model}")

screen = [json.loads(l) for l in open(SCREEN) if l.strip()]
gR = {json.loads(l)["request_id"]: json.loads(l) for l in open(GENR) if l.strip()}
gens = {}
for a in ARMS:
    p = os.path.join(RUN_DIR, f"gen_{a}.jsonl")
    gens[a] = {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()} if os.path.exists(p) else {}

judged = set()
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged.add((r["request_id"], r["arm_id"]))

tokens_used = 0
if os.path.exists(JRAW):
    tokens_used = sum(json.loads(l).get("prompt_tokens", 0) + json.loads(l).get("completion_tokens", 0)
                      for l in open(JRAW) if l.strip())
print(f"judge resume: {len(judged)} rows already judged, judge tokens used {tokens_used:,} (cap {TOKEN_CAP:,})")

def blind(arm, rid):
    return hashlib.sha256(f"{BLSEED}|{arm}|{rid}".encode()).digest()[0] & 1 == 1

# Byte-identical to the stage-05 judge prompt (Pilot 002 craft, unchanged).
SYSTEM = ("You are an impartial, strict evaluator of AI assistant outputs. You compare two "
          "responses to the same user prompt and score each on three axes. Be objective and "
          "consistent across items. Output ONLY valid JSON, no markdown, no commentary.")
TEMPLATE = """[USER PROMPT]
{prompt}

[RESPONSE 1]
{r1}

[RESPONSE 2]
{r2}

Score each response on three axes, integers 0-10:
- correctness: factual/technical correctness relative to what the prompt asks.
- instruction_following: does it do what was asked, completely, without missing parts or extraneous content.
- clarity: coherence, organization, fluency.

Return ONLY this JSON:
{{"response_1": {{"correctness": X, "instruction_following": Y, "clarity": Z}},
 "response_2": {{"correctness": X, "instruction_following": Y, "clarity": Z}}}}"""

def parse_scores(content):
    c = content.strip()
    if c.startswith("```"):
        c = c.strip("`")
        if c.lower().startswith("json"): c = c[4:]
    i, j = c.find("{"), c.rfind("}")
    obj = json.loads(c[i:j+1])
    out = {}
    for k in ("response_1", "response_2"):
        sc = obj[k]
        vals = {a: int(sc[a]) for a in AXES}
        if not all(0 <= v <= 10 for v in vals.values()): raise ValueError("score out of range")
        out[k] = vals
    return out

n_new, n_fail = 0, 0
with open(JRAW, "a") as fj:
    for a in ARMS:
        for rec in screen:
            rid = rec["request_id"]
            if (rid, a) in judged or rid not in gR or rid not in gens[a]:
                continue
            if time.time() - T0 > MAX_SEC:
                print("TIME GUARD: judging aborted; partial log preserved — re-run to resume"); break
            if tokens_used > TOKEN_CAP:
                print(f"TOKEN GUARD: judge tokens {tokens_used:,} exceed cap {TOKEN_CAP:,}; aborting (owner decision required)"); break
            ref_first = blind(a, rid)
            r1, r2 = ((gR[rid]["output_text"], gens[a][rid]["output_text"]) if ref_first
                      else (gens[a][rid]["output_text"], gR[rid]["output_text"]))
            msgs = [dict(role="system", content=SYSTEM),
                    dict(role="user", content=TEMPLATE.format(prompt=rec["prompt"], r1=r1, r2=r2))]
            ok = False
            for attempt, pause in enumerate((5, 15, 30)):
                try:
                    resp = call_api(judge_model, msgs, max_tokens=1024)
                    content = resp["choices"][0]["message"]["content"]
                    if content is None:
                        raise ValueError("null content; raw=" + json.dumps(resp)[:200])
                    scores = parse_scores(content)
                    u = resp.get("usage", {})
                    row = dict(request_id=rid, arm_id=a, judge_model=judge_model,
                               ref_is_response_1=ref_first,
                               scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                               prompt_tokens=u.get("prompt_tokens", 0),
                               completion_tokens=u.get("completion_tokens", 0),
                               raw_content=content, scripts_rev=os.environ["GIT_REV"],
                               ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                    tokens_used += row["prompt_tokens"] + row["completion_tokens"]
                    n_new += 1; ok = True
                    if n_new % 20 == 0 or n_new == 1:
                        print(f"  judged {rid} arm {a}, judge tokens {tokens_used:,}")
                    break
                except Exception as e:
                    print(f"  judge error on {rid} arm {a} (attempt {attempt+1}): {type(e).__name__}: {e}")
                    time.sleep(pause)
            if not ok:
                n_fail += 1
                print(f"  {rid} arm {a}: all retries failed — left for next resume")
print(f"judge phase done: new={n_new} failed={n_fail} judge_tokens={tokens_used:,}")
PY
}

# ---------- helper: arm serve parameters from the manifest ----------
arm_serve_params() {   # $1 = arm_id → prints "<uses_base> <serve_extra>"
  MANIFEST="$MANIFEST" ARM_ID="$1" python3 - <<'PY'
import json, os
man = json.load(open(os.environ["MANIFEST"]))
for a in man["arms"]:
    if a["arm_id"] == os.environ["ARM_ID"]:
        print(("BASE" if a["uses_base_model"] else "CKPT"), a["serve_extra"]); break
else:
    raise SystemExit(f"arm {os.environ['ARM_ID']} not in manifest")
PY
}

# run_arm ARM_ID: build (if needed) → serve → generate → delete checkpoint
run_arm() {   # $1 = arm_id
  local arm="$1"
  local gen_jsonl="$RUN_DIR/gen_${arm}.jsonl"
  if [ "$({ [ -f "$gen_jsonl" ] && wc -l < "$gen_jsonl"; } 2>/dev/null || echo 0)" -ge "$N_SCREEN" ]; then
    echo "arm $arm: generation already complete — skip"; return 0
  fi
  read -r kind extra <<<"$(arm_serve_params "$arm")"
  if [ "$kind" = "BASE" ]; then
    generate_arm "$arm" "$MODEL" "$extra" "$gen_jsonl"
  else
    build_checkpoint "$arm" || die "checkpoint build failed for $arm"
    local cdir="$CKPT_ROOT/$arm"   # deterministic path — never capture builder stdout into a variable
    generate_arm "$arm" "$cdir" "$extra" "$gen_jsonl"
    if [ "${STAGE11_MOCK_BUILD:-0}" != "1" ]; then
      rm -rf "$cdir" && echo "arm $arm: checkpoint deleted after generation (hash anchor in checkpoints.jsonl)"
    fi
  fi
}

# ---------- wave-2 composition (deterministic rule, frozen) ----------
compose_wave2() {
  JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" RECIPE_LOG="$RECIPE_LOG" RECIPES_FILE="$RECIPES_FILE" \
  LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" N_SCREEN="$N_SCREEN" python3 - <<'PY'
import hashlib, json, os, statistics, sys
JRAW = os.environ["JUDGE_RAW_JSONL"]; N = int(os.environ["N_SCREEN"])
rows = [json.loads(l) for l in open(JRAW) if l.strip()]
AXES = ["correctness", "instruction_following", "clarity"]
singles = ["b1-profile-exempt", "b2-smooth-exempt", "b3-a4-kv"]
per = {}
for a in singles:
    rs = [r for r in rows if r["arm_id"] == a]
    if len(rs) < N:
        sys.exit(f"wave-1 judging incomplete for {a} ({len(rs)}/{N}) — judge first")
    cl, ov = [], []
    for r in rs:
        sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
        sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
        cl.append(sA["clarity"] - sR["clarity"])
        ov.append(statistics.mean(sA[x] - sR[x] for x in AXES))
    per[a] = (statistics.mean(cl), statistics.mean(ov))
rank = sorted(singles, key=lambda a: (-per[a][0], -per[a][1], a))
top1, top2 = rank[0], rank[1]
print(f"wave-1 candidate ranking (clarity): " + " > ".join(f"{a}({per[a][0]:+.3f})" for a in rank))

# recipe bodies: static arms live in the gate-layer file; profile-composed
# arms live in the pod-local log (last match wins — append-only semantics)
recs = json.load(open(os.environ["RECIPES_FILE"]))["recipes"]
def body_of(a):
    if a in recs: return recs[a]
    rlog = os.environ["LOCAL_RECIPE_LOG"]
    r = None
    if os.path.exists(rlog):
        for l in open(rlog):
            e = json.loads(l)
            if e.get("arm_id") == a: r = e.get("recipe")
    if r is None: sys.exit(f"recipe body for {a} not found in file or pod-local log")
    return r

def merge(a, b, arm_id):
    ra, rb = body_of(a), body_of(b)
    qa, qb = ra["quantization"], rb["quantization"]
    scheme = "FP8_DYNAMIC" if "FP8_DYNAMIC" in (qa["scheme"], qb["scheme"]) else qa["scheme"]
    over = qa.get("scheme_overrides") or qb.get("scheme_overrides")
    ignore = list(dict.fromkeys(qa["ignore"] + qb["ignore"]))
    r = dict(arm_id=arm_id, builder="llmcompressor-oneshot",
             levers=sorted(set(ra.get("levers", []) + rb.get("levers", []))),
             quantization=dict(targets="Linear", scheme=scheme, ignore=ignore),
             calibration=ra["calibration"],
             serve_extra="--quantization compressed-tensors", uses_base_model=False)
    if over: r["quantization"]["scheme_overrides"] = over
    sm = ra.get("smoothing") or rb.get("smoothing")
    if sm: r["smoothing"] = sm
    kv = ra.get("kv_cache_scheme") or rb.get("kv_cache_scheme")
    if kv: r["kv_cache_scheme"] = kv
    return r

existing = set()
if os.path.exists(os.environ["RECIPE_LOG"]):
    for l in open(os.environ["RECIPE_LOG"]):
        existing.add(json.loads(l).get("arm_id"))
os.makedirs(os.path.dirname(os.environ["LOCAL_RECIPE_LOG"]), exist_ok=True)
for arm_id, pair in (("b4-w2", (top1, top2)),):
    if arm_id in existing:
        print(f"{arm_id}: composed recipe already archived — resume skip"); continue
    r = merge(pair[0], pair[1], arm_id)
    sha = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    # custody split: hashes + labels to the public archive; full body pod-local only
    with open(os.environ["RECIPE_LOG"], "a") as f:
        f.write(json.dumps(dict(arm_id=arm_id, composed_from=list(pair), levers=r["levers"],
                                recipe_sha256=sha), sort_keys=True) + "\n")
    with open(os.environ["LOCAL_RECIPE_LOG"], "a") as f:
        f.write(json.dumps(dict(arm_id=arm_id, composed_from=list(pair), levers=r["levers"],
                                recipe=r, recipe_sha256=sha), sort_keys=True) + "\n")
    print(f"{arm_id}: composed from {pair[0]} + {pair[1]} → recipe_sha256={sha[:16]}…")
PY
}

# ---------- orchestration ----------
note "4. reference arm R: hardware-local BF16 generations inherited from stage 10 (no generation here)"
[ -s "$GEN_R_JSONL" ] || die "gen_R.jsonl missing/empty — stage-10 anchor phase must complete first"
echo "  gen_R (H100): $(wc -l < "$GEN_R_JSONL") rows, sha256=$(sha256sum "$GEN_R_JSONL" | cut -c1-16)…"

note "5. wave 1: 4 arms (control + 3 retry candidates)"
for arm in b0-control b1-profile-exempt b2-smooth-exempt b3-a4-kv; do
  [ $(( $(date +%s) - START_TS )) -lt "$MAX_SECONDS" ] || die "time rail tripped — re-run to resume"
  run_arm "$arm"
done

note "6. judging wave 1 (screening judge)"
judge_arms b0-control b1-profile-exempt b2-smooth-exempt b3-a4-kv

note "7. wave 2: deterministic composition from wave-1 ranking"
compose_wave2
for arm in b4-w2; do
  [ $(( $(date +%s) - START_TS )) -lt "$MAX_SECONDS" ] || die "time rail tripped — re-run to resume"
  run_arm "$arm"
done

note "8. judging wave 2"
judge_arms b4-w2

# ---------- verdict + completeness gate ----------
note "9. screening verdict (recomputed from archived logs)"
set +e
run_verdict
RC_V=$?
set -e

if [ "$RC_V" -eq 0 ] || [ "$RC_V" -eq 2 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  if [ "$RC_V" -eq 0 ]; then
    echo "STAGE 11 LEVER SCREENING: COMPLETE — outcome PROCEED (winner in winner.json; next: stage 12 single-shot confirm)"
  else
    echo "STAGE 11 LEVER SCREENING: COMPLETE — outcome SCREENING-EXHAUSTED (publishable FAIL; see verdict_s.txt)"
  fi
  exit "$RC_V"   # 0=PROCEED-complete, 2=EXHAUSTED-complete (frozen exit-code contract)
else
  echo "STAGE 11 LEVER SCREENING: INCOMPLETE (no COMPLETE marker — re-run the same command to resume)"
  exit 1
fi
