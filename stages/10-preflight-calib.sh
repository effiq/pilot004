#!/usr/bin/env bash
# =============================================================================
# Pilot 004 — STAGE 10: PREFLIGHT + H100 CALIBRATION (foundation stage)
#
# Pre-registered in PROTOCOL-LOCK v3.0 (frozen before execution). Pilot 004
# moves the evidence chain to ONE H100 SXM 80GB. This stage lays every
# foundation the later stages consume, each byte-anchored:
#
#   1. Environment anchors: golden-stack assertion (torch 2.13.0+cu130 /
#      vLLM 0.31.0 / compressed-tensors 0.17.0 / transformers 5.10.4 /
#      llmcompressor 0.12.0 / datasets 4.8.4 / accelerate 1.13.0 — the
#      Pilot 003 terminal stack) with a pinned auto-repair sequence;
#      pip freeze archived in full; GPU must be H100 (L3 boundary);
#      disk >= 150GB; network volume writable (004 tooling).
#   2. Trace plans: the six formal slice pairs + the watermarked
#      calibration pair are derived on this pod by running Pilot 002's
#      PUBLIC stage-01 code, then asserted byte-identical against the
#      merged_sha256 chain archived in pilot-logs (002 manifest). If plans
#      already exist locally with matching hashes (e.g. preserved on the
#      network volume), derivation is skipped. Output hashes are the
#      anchor; code provenance (pilot002 HEAD) is recorded.
#   3. H100 operating-point recalibration: Pilot 002's stage-02 rule,
#      unchanged — frozen grid order, decreasing offered load, SLO =
#      TTFT<=5s AND TPOT<=100ms, first config with >=95% compliance wins;
#      tier-1 live abort (noncompliant > 5% of scheduled) and tier-2
#      window-end abort (noncompliant > 5% of engaged) exactly as archived;
#      all-fail -> lightest config (D=256, C=4) with the fallback
#      disclosure carried into every downstream verdict. Calibrated on
#      arm A (BF16) — the slowest arm; a point that holds for BF16 holds
#      for B and C. ALL calibration rows are watermarked: CALIBRATION DATA
#      ONLY — never enters the CI.
#   4. Anchor assembly: frozen 150 set (sha 728b2f83…), blind map
#      (684aea8d…) and the historical L40S gen_A (16df35cc…) copied from
#      the sealed Pilot 002 archive; screening set (d0b3da96…) and the
#      256 calibration texts (f7020a78…) copied from the Pilot 003
#      archive. Every copy sha-asserted.
#   5. Hardware-local references: gen_A (frozen 150) and gen_R (screening
#      40) REGENERATED on this H100 with BF16 defaults (temperature 0,
#      natural stopping, concurrency 8) — judging comparisons are
#      hardware-local by design.
#   6. Optional dry-run (STAGE10_DRYRUN=1): Qwen2.5-0.5B mini pipeline —
#      one exemption checkpoint via real llmcompressor oneshot, real vLLM
#      serve, 2-prompt generation, custody writes exercised. Tooling
#      validation only; produces no evidence. Doubles as the
#      model-portability rig for later pilots.
#
# This stage judges nothing and measures nothing for the verdict.
#
# Verify entry: bash stages/10-preflight-calib.sh --verify <run_dir>
#   Re-audits every recorded sha256 against the files on disk.
#
# Test hooks (sandbox only, never set in production):
#   STAGE10_OUT_DIR, STAGE10_SKIP_GPU, STAGE10_SKIP_ENV, STAGE10_SKIP_VOLUME,
#   STAGE10_SKIP_DISK, STAGE10_SKIP_SERVER, STAGE10_SKIP_ANCHORS, STAGE10_MOCK_CALIB,
#   STAGE10_MOCK_BUILD, STAGE10_DRYRUN, STAGE10_PLANS_DIR, PORT,
#   MAX_SECONDS, KEY_FILE, VOLUME_DIR, EFFIQ_HOME, LOGS_DIR, SCRIPTS_DIR,
#   TRACE_DIR
# =============================================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot004}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="${STAGE10_PLANS_DIR:-$TRACE_DIR/plans}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_NAME="10-preflight-calib"

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
DRYRUN_MODEL="Qwen/Qwen2.5-0.5B-Instruct"             # tooling validation only
VLLM_PINNED="0.31.0"
TORCH_PINNED="2.13.0"        # prefix match (2.13.0+cu130)
CT_PINNED="0.17.0"           # compressed-tensors
TF_PINNED="5.10.4"           # transformers
LC_PINNED="0.12.0"           # llmcompressor
DS_PINNED="4.8.4"            # datasets
AC_PINNED="1.13.0"           # accelerate
GPU_EXPECT="H100"
MAX_MODEL_LEN=32768
GEN_CONC=8

FROZEN_SHA="728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d"   # Pilot 002 frozen 150
GENA_L40S_SHA="16df35ccad32cc60a5785ce87fa96e325487b66ec3000e3fa04e6479b886c8cd" # historical L40S reference
BLIND_SHA="684aea8dcc33ce4f88d9aa8644007cdb8ace0e4ff331a124b8c62fe1c7e76392"
SCREEN_SHA="d0b3da96251019d34006ade5fdb0017b3850770abeabc89cc8a6f16a29a9b5ab"   # Pilot 003 screening 40
CALIB_TEXTS_SHA="f7020a784e8745c79ccfe4a8a810f1d05738ee0ae9eab9245e755cbc1aac8ab8" # 256 calibration texts
N_FROZEN=150
N_SCREEN=40

# Pilot 002 stage-01 merged-plan sha256 chain (archived in pilot-logs manifest)
PLAN_SHA_pair_1="0c0fcf14b33ce205f4d74d232bf682151c4ba4bf7aa12d8c1c99347f4c64b0c2"
PLAN_SHA_pair_2="831d4a8ba47744c5b2f395e876a82770d264be675c8b5ff3d55a8f769e2957c3"
PLAN_SHA_pair_3="f3ab804060981c3e3b63609867ec0e85fe914428fd249e5fb58274c7bb3a8b75"
PLAN_SHA_pair_4="8e9753f620d3887624dd8592defab4cba2ec3a7ccbbf5149601b223b3081950e"
PLAN_SHA_pair_5="5784d2d126a7ebc322e3c963e800cbd03c86e61c0ca608424e5b41cd0de68429"
PLAN_SHA_pair_6="4d2cdcae86b8e6213150bc52cd217e51a949d4e9c1f4c8258a3b5dce951ffbec"
PLAN_SHA_calibration="d9f94896776893e620875381d4acbdbffd8b9b773599b3515f356cde06ce7108"
PLAN_IDS="pair_1 pair_2 pair_3 pair_4 pair_5 pair_6 calibration"
P2_REPO_URL="https://github.com/effiq/pilot002.git"

# Calibration rule (Pilot 002 stage-02, frozen; grid order byte-copied from the archive)
GRID_ORDER="1 16|2 16|1 8|4 16|2 8|1 4|8 16|4 8|2 4|16 16|8 8|4 4|32 16|16 8|8 4|64 16|32 8|16 4|128 16|64 8|32 4|256 16|128 8|64 4|256 8|128 4|256 4"
SLO_TTFT_S=5.0
SLO_TPOT_MS=100.0
COMPLIANCE_MIN=0.95
REQ_TIMEOUT_S=900
CLIENT_CONC=2048
MAX_TOKENS_CAP=1024
FILLER_SEED=20261010
WATERMARK="CALIBRATION DATA ONLY — never enters the CI"

KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
VOLUME_DIR="${VOLUME_DIR:-/workspace}"
MAX_SECONDS="${MAX_SECONDS:-43200}"                   # 12 h rail
PORT="${PORT:-8000}"                                  # test hook only

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\n\033[1;31m[stage10][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

set_paths() {
  RUN_DIR="$1"
  FROZEN_JSONL="$RUN_DIR/frozen_set.jsonl"
  BLIND_JSONL="$RUN_DIR/blind_map.jsonl"
  GENA_L40S_JSONL="$RUN_DIR/gen_A_L40S_reference.jsonl"
  SCREEN_JSONL="$RUN_DIR/screening_set.jsonl"
  CALIB_TXT_JSONL="$RUN_DIR/calibration_texts.jsonl"
  GENA_JSONL="$RUN_DIR/gen_A.jsonl"
  GENR_JSONL="$RUN_DIR/gen_R.jsonl"
  CHOSEN_JSON="$RUN_DIR/chosen_004.json"
  PIP_FREEZE="$RUN_DIR/pip_freeze.txt"
  ANCHORS_JSON="$RUN_DIR/anchors.json"
}

sha_file() { sha256sum "$1" | cut -d' ' -f1; }

# ---------- --verify: re-audit every recorded hash against the files on disk ----------
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  if [ -z "$D" ]; then D="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$D" ] && [ -f "$D/anchors.json" ] || { echo "VERIFY: usage: --verify <run_dir> (no anchors.json found)"; exit 1; }
  echo "verify: re-auditing recorded sha256 values against files in $D (no network, no GPU)"
  ANCHORS_JSON="$D/anchors.json" RUN_DIR="$D" python3 - <<'PY'
import hashlib, json, os, sys
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
a = json.load(open(os.environ["ANCHORS_JSON"]))
bad = []
for name, want in sorted(a.get("files", {}).items()):
    p = os.path.join(os.environ["RUN_DIR"], name)
    got = sha(p) if os.path.exists(p) else "MISSING"
    status = "OK" if got == want else "MISMATCH"
    if got != want: bad.append(name)
    print(f"  {name}: {status} ({got[:16]}…)")
if bad:
    print("VERIFY: MISMATCH — " + ", ".join(bad), file=sys.stderr); sys.exit(1)
print("VERIFY: all recorded hashes match the files on disk")
print("VERIFY: ALL CHECKS PASSED")
PY
  exit $?
fi

# ---------- run bookkeeping: resume-or-create; COMPLETE re-entry guard ----------
note "0. run bookkeeping"
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)
if [ -n "${STAGE10_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE10_OUT_DIR"; mkdir -p "$RUN_DIR"
else
  LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
    echo "STAGE 10 already COMPLETE: $LATEST"
    echo "anchors: $LATEST/anchors.json  (re-audit: bash stages/10-preflight-calib.sh --verify $LATEST)"
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
T0=$(date +%s)

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  [ "$elapsed" -gt "$MAX_SECONDS" ] && \
    die "time rail tripped (${elapsed}s) — completed phases carry their artifacts; re-run tonight.sh to resume."
  return 0
}

# ---------- phase 1: environment anchors (golden stack; pinned auto-repair) ----------
note "1. environment anchors (golden stack, H100, disk, volume)"
date -u
hostname || true
echo "scripts_rev=$GIT_REV"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true

if [ "${STAGE10_SKIP_GPU:-0}" != "1" ]; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  [[ "$GPU_NAME" == *"$GPU_EXPECT"* ]] || die "expected $GPU_EXPECT, found '$GPU_NAME' (hardware boundary, L3 — Pilot 004 claims are H100-scoped)"
  echo "gpu: $GPU_NAME"
else
  echo "TEST HOOK: STAGE10_SKIP_GPU=1 (sandbox only)"
fi

env_check() {   # prints nothing on success; returns 1 on mismatch
  TORCH_PINNED="$TORCH_PINNED" VLLM_PINNED="$VLLM_PINNED" CT_PINNED="$CT_PINNED" \
  TF_PINNED="$TF_PINNED" LC_PINNED="$LC_PINNED" DS_PINNED="$DS_PINNED" AC_PINNED="$AC_PINNED" \
  python3 - <<'PY' >/dev/null 2>&1
import os
import importlib
def ver(mod):
    try: return importlib.import_module(mod).__version__
    except Exception: return None
checks = [
    ("torch",            os.environ["TORCH_PINNED"], "prefix"),
    ("vllm",             os.environ["VLLM_PINNED"],  "exact"),
    ("compressed_tensors", os.environ["CT_PINNED"],  "exact"),
    ("transformers",     os.environ["TF_PINNED"],    "exact"),
    ("llmcompressor",    os.environ["LC_PINNED"],    "exact"),
    ("datasets",         os.environ["DS_PINNED"],    "exact"),
    ("accelerate",       os.environ["AC_PINNED"],    "exact"),
]
for mod, want, mode in checks:
    got = ver(mod)
    ok = got is not None and (got.startswith(want) if mode == "prefix" else got == want)
    if not ok:
        raise SystemExit(1)
PY
}

if [ "${STAGE10_SKIP_ENV:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE10_SKIP_ENV=1 — golden-stack assertion skipped (sandbox only)"
else
  if ! env_check; then
    echo "golden stack mismatch — running the pinned repair sequence (Pilot 003 terminal-stack doctrine:"
    echo "  engine deps are immovable; the builder adapts around them)"
    pip install -q "vllm==$VLLM_PINNED"
    pip install -q --no-deps "llmcompressor==$LC_PINNED"
    pip install -q "transformers==$TF_PINNED" "datasets==$DS_PINNED" "accelerate==$AC_PINNED" \
        loguru nvidia-ml-py pillow httpx
    env_check || die "golden stack still not satisfied after pinned repair — see versions above; owner decision required"
    echo "golden stack repaired and verified"
  else
    echo "golden stack verified (torch $TORCH_PINNED+ / vllm $VLLM_PINNED / ct $CT_PINNED / tf $TF_PINNED / lc $LC_PINNED / datasets $DS_PINNED / accelerate $AC_PINNED)"
  fi
fi
python3 -m pip freeze > "$PIP_FREEZE" 2>/dev/null || pip freeze > "$PIP_FREEZE"
echo "pip_freeze_sha256=$(sha_file "$PIP_FREEZE")"

FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
if [ "${STAGE10_SKIP_DISK:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE10_SKIP_DISK=1 (sandbox only; free=${FREE_GB}GB)"
else
  [ "${FREE_GB:-0}" -ge 150 ] || die "disk headroom < 150GB (base weights 33GB + checkpoint builds ~16GB each + trace plans; Pilot 003 lesson 7be)"
  echo "disk headroom: ${FREE_GB}GB (>=150 required)"
fi

if [ "${STAGE10_SKIP_VOLUME:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE10_SKIP_VOLUME=1 (sandbox only)"
else
  if [ -d "$VOLUME_DIR" ] && [ -w "$VOLUME_DIR" ]; then
    echo "network volume writable: $VOLUME_DIR"
  else
    die "network volume missing or not writable at $VOLUME_DIR — Pilot 004 requires a mounted volume (pod-rebuild survivability, 004 tooling)"
  fi
fi
[ -f "$KEY_FILE" ] || die "judge key not found at $KEY_FILE (needed by stages 11/12 — fail early)"
python3 -c "import httpx" 2>/dev/null || pip install -q httpx

# ---------- phase 2: trace plans (byte-anchored to the Pilot 002 manifest chain) ----------
note "2. trace plans (pair_1..6 + watermarked calibration pair)"
plan_sha_ok() {   # $1 = plan_id → 0 if file exists and sha matches the embedded anchor
  local pid="$1"
  local want_var="PLAN_SHA_${pid}"
  local want="${!want_var}"
  local f="$PLANS_DIR/$pid.jsonl"
  [ -f "$f" ] || return 1
  [ "$(sha_file "$f")" = "$want" ]
}

PLANS_OK=1
for pid in $PLAN_IDS; do
  if plan_sha_ok "$pid"; then
    echo "  [$pid] present, sha256 matches the 002 manifest anchor"
  else
    PLANS_OK=0
  fi
done

if [ "$PLANS_OK" = "0" ] && [ "${STAGE10_SKIP_ANCHORS:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE10_SKIP_ANCHORS=1 — fabricating synthetic plans, 002 manifest anchors bypassed (sandbox only)"
  PLANS_DIR="$PLANS_DIR" python3 - <<'PY'
import json, os, random
pd = os.environ["PLANS_DIR"]
os.makedirs(pd, exist_ok=True)
rng = random.Random(999)   # sandbox-only fixture, any seed; never an anchor
for pid in ["pair_1", "pair_2", "pair_3", "pair_4", "pair_5", "pair_6", "calibration"]:
    p = os.path.join(pd, f"{pid}.jsonl")
    if os.path.exists(p):
        continue
    with open(p, "w") as f:
        for i in range(60):
            f.write(json.dumps({
                "request_id": f"{pid}-req-{i:04d}", "pair_id": pid,
                "service": "conv" if i % 2 == 0 else "code",
                "arrival_offset_s": round(i * 0.5, 3),
                "keep_u": rng.random(),
                "context_tokens": rng.randrange(500, 3000),
                "generated_tokens": rng.randrange(20, 200)}, sort_keys=True) + "\n")
    print(f"  fabricated {p}")
PY
  PLANS_OK=1
fi

if [ "$PLANS_OK" = "0" ]; then
  echo "plans missing or mismatched — deriving from the raw Azure trace via Pilot 002's PUBLIC stage-01 code"
  P2_DIR="$EFFIQ_HOME/pilot002"
  if [ ! -d "$P2_DIR/.git" ]; then
    ok=0
    for attempt in 1 2 3 4 5; do
      git clone --quiet "$P2_REPO_URL" "$P2_DIR" && ok=1 && break
      echo "  pilot002 clone attempt $attempt failed — retrying in 10s"; sleep 10
    done
    [ "$ok" = "1" ] || die "cannot clone $P2_REPO_URL (network?) — plans derivation requires Pilot 002's public stage-01 code"
  fi
  P2_REV="$(git -C "$P2_DIR" rev-parse HEAD)"
  echo "pilot002 HEAD (code provenance): $P2_REV"
  [ -f "$P2_DIR/stages/01-trace-pipeline.sh" ] || die "pilot002 clone lacks stages/01-trace-pipeline.sh"
  EFFIQ_HOME="$EFFIQ_HOME" LOGS_DIR="$LOGS_DIR" TRACE_DIR="$TRACE_DIR" \
    bash "$P2_DIR/stages/01-trace-pipeline.sh" || die "pilot002 stage-01 derivation failed — send the log to the engineering owner"
  for pid in $PLAN_IDS; do
    plan_sha_ok "$pid" || die "derived plan $pid sha256 != 002 manifest anchor — derivation did not reproduce the archived bytes; halt and escalate"
  done
  echo "all plans derived and byte-verified against the archived manifest chain"
else
  echo "all plans already present and byte-verified (volume/archive reuse)"
fi
P2_REV_RECORD="$(git -C "$EFFIQ_HOME/pilot002" rev-parse HEAD 2>/dev/null || echo not-cloned-reused-local-plans)"

# ---------- phase 3: H100 operating-point recalibration (002 stage-02 rule, unchanged) ----------
note "3. H100 recalibration (frozen grid order; SLO TTFT<=${SLO_TTFT_S}s TPOT<=${SLO_TPOT_MS}ms; >=${COMPLIANCE_MIN} compliance)"
if [ -f "$CHOSEN_JSON" ]; then
  echo "chosen_004.json already present — resume skip"
  python3 -c "import json; d=json.load(open('$CHOSEN_JSON')); print('  operating point: D=%s C=%s fallback=%s' % (d['D'], d['C'], d.get('fallback')))"
else
  [ -f "$PLANS_DIR/calibration.jsonl" ] || die "calibration pair plan missing — phase 2 must complete first"
  if [ "${STAGE10_MOCK_CALIB:-0}" = "1" ]; then
    echo "TEST HOOK: STAGE10_MOCK_CALIB=1 — writing a synthetic calibration outcome (sandbox only)"
    python3 - "$CHOSEN_JSON" "$WATERMARK" <<'PY'
import json, sys
json.dump({"D": 64, "C": 8, "r": "1/64", "fallback": False, "mock": True,
           "hardware": "H100 SXM 80GB", "watermark": sys.argv[2],
           "rule": "first config in decreasing offered-load order with >=95% SLO compliance (TTFT<=5s, TPOT<=100ms); fallback = lightest config with disclosure",
           "attempted": [{"D": 1, "C": 16, "status": "ABORTED-FAIL", "watermark": sys.argv[2]},
                          {"D": 64, "C": 8, "status": "PASS", "watermark": sys.argv[2]}]},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  else
    check_time_rail
    # calibration server: arm A = BF16 base (slowest arm — a point that holds here holds for B/C)
    CALIB_SLOG="$RUN_DIR/server_calib.log"
    if [ "${STAGE10_SKIP_SERVER:-0}" != "1" ]; then
      echo "starting BF16 server for calibration (prefix caching OFF)"
      nohup python -m vllm.entrypoints.openai.api_server \
        --model "$MODEL" --revision "$MODEL_REV" \
        --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
        --port "$PORT" > "$CALIB_SLOG" 2>&1 &
      echo $! > "$RUN_DIR/server.pid"
      waited=0
      until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
        sleep 10; waited=$((waited+10))
        if [ "$waited" -ge 2400 ]; then die "calibration server failed to become healthy — see $CALIB_SLOG"; fi
        if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "calibration server process died — see $CALIB_SLOG"; fi
      done
      echo "calibration server healthy after ${waited}s"
    else
      echo "TEST HOOK: STAGE10_SKIP_SERVER=1 — external server on port $PORT"
    fi

    IFS='|' read -ra GRID <<< "$GRID_ORDER"
    CHOSEN=""
    for cfg in "${GRID[@]}"; do
      read -r D C <<< "$cfg"
      DONE_MK="$RUN_DIR/calib_d${D}_c${C}.done"
      if [ -f "$DONE_MK" ]; then
        st=$(python3 -c "import json; print(json.load(open('$DONE_MK'))['status'])" 2>/dev/null || echo "?")
        echo "  grid D=$D C=$C: already attempted ($st) — resume skip"
        if [ "$st" = "PASS" ] && [ -z "$CHOSEN" ]; then CHOSEN="$D $C"; fi
        continue
      fi
      [ -z "$CHOSEN" ] || break
      check_time_rail
      echo "  grid D=$D C=$C: replaying calibration pair (watermarked)…"
      # rc=3 (FAIL, continue grid scan) must be catchable — shield this invocation from set -e.
      set +e
      RUN_DIR="$RUN_DIR" PLAN="$PLANS_DIR/calibration.jsonl" PORT="$PORT" MODEL="$MODEL" \
      D_CHOSEN="$D" C_CHOSEN="$C" WATERMARK="$WATERMARK" \
      SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" COMPLIANCE_MIN="$COMPLIANCE_MIN" \
      REQ_TIMEOUT_S="$REQ_TIMEOUT_S" CLIENT_CONC="$CLIENT_CONC" \
      MAX_TOKENS_CAP="$MAX_TOKENS_CAP" MAX_MODEL_LEN="$MAX_MODEL_LEN" \
      FILLER_SEED="$FILLER_SEED" GIT_REV="$GIT_REV" python3 - <<'PY'
import asyncio, hashlib, json, os, random, sys, time
import httpx

RUN_DIR = os.environ["RUN_DIR"]; PLAN = os.environ["PLAN"]
PORT = os.environ["PORT"]; MODEL = os.environ["MODEL"]
D0, C0 = int(os.environ["D_CHOSEN"]), int(os.environ["C_CHOSEN"])
R = 1.0 / D0; WINDOW = 3600.0 / C0
WM = os.environ["WATERMARK"]
TTFT_SLO = float(os.environ["SLO_TTFT_S"]); TPOT_SLO = float(os.environ["SLO_TPOT_MS"])
CMIN = float(os.environ["COMPLIANCE_MIN"])
REQ_TO = float(os.environ["REQ_TIMEOUT_S"]); CONC = int(os.environ["CLIENT_CONC"])
CAP = int(os.environ["MAX_TOKENS_CAP"]); MML = int(os.environ["MAX_MODEL_LEN"])
FSEED = int(os.environ["FILLER_SEED"])
URL = f"http://127.0.0.1:{PORT}/v1/completions"
RAW = os.path.join(RUN_DIR, f"calib_d{D0}_c{C0}.jsonl")
DONE_F = os.path.join(RUN_DIR, f"calib_d{D0}_c{C0}.done")

rows = [json.loads(l) for l in open(PLAN)]
rows.sort(key=lambda r: (r["arrival_offset_s"], r["service"], r["request_id"]))
sched = [(row["arrival_offset_s"] / C0, row) for row in rows if row["keep_u"] < R]
n_sched = len(sched)
max_ctx = max(r["context_tokens"] for _, r in sched) if sched else 8192
print(f"    D={D0} C={C0}: thinned {n_sched:,} offered over {WINDOW:.0f}s (≈{n_sched/WINDOW:.2f} req/s), max ctx {max_ctx:,}", flush=True)

_rng = random.Random(FSEED)
_base = [_rng.randrange(1000, 50000) for _ in range(8192)]
G = (_base * (max_ctx // 8192 + 2))[: max_ctx + 8192]
def filler_ids(n, rid):
    off = int.from_bytes(hashlib.sha256(f"{FSEED}|{rid}".encode()).digest()[:4], "big") % 8192
    return G[off:off + n]

sent = done = noncomp = 0
abort_tier = [None]
t0 = time.monotonic()

async def replay(client, raw_f):
    global sent, done, noncomp
    sem = asyncio.Semaphore(CONC)

    async def fire(at, row):
        global sent, done, noncomp
        rid = row["request_id"]; ctx, gen = row["context_tokens"], row["generated_tokens"]
        rec = {"request_id": rid, "service": row["service"], "watermark": WM,
               "arrival_offset_s": row["arrival_offset_s"], "prompt_tokens": ctx,
               "max_tokens_target": min(gen, CAP, MML - ctx - 1), "D": D0, "C": C0,
               "scripts_rev": os.environ["GIT_REV"]}
        if rec["max_tokens_target"] <= 0:
            rec.update(status="skipped_overlength", slo_ok=False)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush(); done += 1; return
        async with sem:
            if abort_tier[0]:
                return
            sent += 1
            payload = {"model": MODEL, "prompt": filler_ids(ctx, rid),
                       "max_tokens": rec["max_tokens_target"], "ignore_eos": True,
                       "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True}}
            t_send = time.monotonic()
            t_first = t_last = None; comp = 0
            status = "ok"
            try:
                async with client.stream("POST", URL, json=payload) as resp:
                    if resp.status_code != 200:
                        status = f"http_{resp.status_code}"
                    else:
                        async for line in resp.aiter_lines():
                            if not line.startswith("data:"): continue
                            data = line[5:].strip()
                            if data == "[DONE]": break
                            try: obj = json.loads(data)
                            except Exception: continue
                            now = time.monotonic()
                            if t_first is None: t_first = now
                            t_last = now
                            u = obj.get("usage")
                            if u: comp = u.get("completion_tokens", comp)
            except Exception as e:
                status = "error:" + type(e).__name__
            t_end = time.monotonic()
            ttft = (t_first - t_send) if t_first is not None else None
            tpot = ((t_last - t_first) / (comp - 1) * 1000.0) if (t_first is not None and comp > 1) else None
            ok = (status == "ok" and ttft is not None and ttft <= TTFT_SLO
                  and tpot is not None and tpot <= TPOT_SLO)
            rec.update(status=status, completion_tokens=comp,
                       ttft_s=round(ttft, 4) if ttft is not None else None,
                       tpot_ms=round(tpot, 3) if tpot is not None else None,
                       e2e_s=round(t_end - t_send, 4), slo_ok=ok)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            if done > 0 and not ok and status != "skipped_overlength":
                noncomp += 1

    async def sender():
        for at, row in sched:
            if abort_tier[0]: break
            delay = at - (time.monotonic() - t0)
            if delay > 0: await asyncio.sleep(delay)
            asyncio.create_task(fire(at, row))

    async def watchdog():
        # tier-1 live abort: noncompliant > 5% of SCHEDULED (002 stage-02 rule, verbatim)
        while done < n_sched and not abort_tier[0]:
            await asyncio.sleep(5)
            if sent >= 200 and noncomp > 0.05 * n_sched:
                abort_tier[0] = "tier1: noncompliant > 5% of scheduled"
                break

    sd = asyncio.create_task(sender()); wd = asyncio.create_task(watchdog())
    await sd
    if not abort_tier[0] and sent > 0 and noncomp > 0.05 * sent:
        # tier-2 window-end abort: noncompliant > 5% of ENGAGED (002 stage-02 rule, verbatim)
        abort_tier[0] = "tier2: window elapsed, noncompliant > 5% of engaged"
    if abort_tier[0]:
        pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task() and t not in (sd, wd)]
        for t in pending: t.cancel()
        await asyncio.sleep(1)
    else:
        pending = {t for t in asyncio.all_tasks() if t is not asyncio.current_task() and t not in (sd, wd)}
        deadline = time.monotonic() + REQ_TO + 120.0
        while pending:
            if time.monotonic() > deadline:
                for t in pending: t.cancel()
            _, pending = await asyncio.wait(pending, timeout=5.0, return_when=asyncio.FIRST_COMPLETED)
    wd.cancel()

async def main():
    limits = httpx.Limits(max_connections=CONC, max_keepalive_connections=min(CONC, 256))
    timeout = httpx.Timeout(REQ_TO, connect=30.0)
    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        with open(RAW, "w") as raw_f:
            raw_f.write(json.dumps({"type": "header", "watermark": WM, "D": D0, "C": C0,
                                    "r": f"1/{D0}", "window_s": WINDOW,
                                    "slo": {"ttft_s": TTFT_SLO, "tpot_ms": TPOT_SLO},
                                    "scripts_rev": os.environ["GIT_REV"],
                                    "started_wall": round(time.time(), 3)}) + "\n")
            await replay(client, raw_f)
    engaged = sent
    if abort_tier[0]:
        res = {"D": D0, "C": C0, "status": "ABORTED-FAIL", "scheduled": n_sched,
               "sent": sent, "noncompliant": noncomp,
               "compliance": round(1 - noncomp / max(engaged, 1), 6),
               "watermark": WM, "abort_reason": abort_tier[0]}
    else:
        compliance = 1 - noncomp / max(engaged, 1)
        res = {"D": D0, "C": C0, "status": "PASS" if compliance >= CMIN else "FAIL",
               "scheduled": n_sched, "sent": sent, "noncompliant": noncomp,
               "compliance": round(compliance, 6), "watermark": WM}
    json.dump(res, open(DONE_F, "w"), indent=2, sort_keys=True)
    print(f"    D={D0} C={C0}: {res['status']} compliance={res['compliance']:.4f} (engaged={engaged})", flush=True)
    sys.exit(0 if res["status"] == "PASS" else 3)

asyncio.run(main())
PY
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then CHOSEN="$D $C"; fi
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        die "calibration client failed at D=$D C=$C (rc=$rc) — incident recorded; re-run to resume"
      fi
    done

    if [ "${STAGE10_SKIP_SERVER:-0}" != "1" ]; then
      [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
      sleep 5; pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
    fi

    if [ -n "$CHOSEN" ]; then
      read -r CD CC <<< "$CHOSEN"
      python3 - "$CHOSEN_JSON" "$CD" "$CC" "$WATERMARK" <<'PY'
import json, sys
json.dump({"D": int(sys.argv[2]), "C": int(sys.argv[3]), "r": f"1/{sys.argv[2]}", "fallback": False,
           "hardware": "H100 SXM 80GB", "watermark": sys.argv[4],
           "rule": "first config in decreasing offered-load order with >=95% SLO compliance (TTFT<=5s, TPOT<=100ms); fallback = lightest config with disclosure"},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
      echo "operating point chosen: D=$CD C=$CC (r=1/$CD, window $((3600 / CC))s) — first passing config in frozen grid order"
    else
      python3 - "$CHOSEN_JSON" "$WATERMARK" <<'PY'
import json, sys
json.dump({"D": 256, "C": 4, "r": "1/256", "fallback": True,
           "hardware": "H100 SXM 80GB", "watermark": sys.argv[2],
           "disclosure": "no grid configuration met the SLO; lightest configuration used, shortfall disclosed per protocol",
           "rule": "first config in decreasing offered-load order with >=95% SLO compliance (TTFT<=5s, TPOT<=100ms); fallback = lightest config with disclosure"},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
      echo "FALLBACK: no grid configuration met the SLO on H100 — lightest config D=256 C=4 with disclosure (carried into every downstream verdict)"
    fi
  fi
fi

# ---------- phase 4: anchor assembly (sha-asserted copies from sealed archives) ----------
note "4. anchor assembly (002 frozen set / blind map / historical gen_A; 003 screening set / calibration texts)"

find_archive_dir() {   # $1 = stage dir name → latest COMPLETE run dir
  local s="$1" d
  for d in $(ls -dt "$LOGS_DIR"/*/"$s"/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && echo "$d" && return 0
  done
  return 1
}

copy_assert() {   # $1 = src file, $2 = dest file, $3 = expected sha, $4 = label
  local src="$1" dst="$2" want="$3" label="$4"
  if [ -f "$dst" ] && [ "$(sha_file "$dst")" = "$want" ]; then
    echo "  $label: already anchored (sha OK) — resume skip"; return 0
  fi
  [ -f "$src" ] || die "$label source missing: $src"
  local got; got="$(sha_file "$src")"
  [ "$got" = "$want" ] || die "$label sha256 mismatch: $got != $want — refusing to build on unverified anchors"
  cp "$src" "$dst"
  echo "  $label anchored: $want"
}

if [ "${STAGE10_SKIP_ANCHORS:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE10_SKIP_ANCHORS=1 — anchor hash asserts skipped (sandbox only)"
  SRC05_DIR="${STAGE10_SRC05_DIR:-}"; SRC07_DIR="${STAGE10_SRC07_DIR:-}"
  [ -n "$SRC05_DIR" ] && for f in frozen_set.jsonl blind_map.jsonl; do [ -f "$RUN_DIR/$f" ] || cp "$SRC05_DIR/$f" "$RUN_DIR/$f"; done
  [ -n "$SRC05_DIR" ] && [ -f "$SRC05_DIR/gen_A.jsonl" ] && [ ! -f "$GENA_L40S_JSONL" ] && cp "$SRC05_DIR/gen_A.jsonl" "$GENA_L40S_JSONL"
  [ -n "$SRC07_DIR" ] && for f in screening_set.jsonl calibration_texts.jsonl; do [ -f "$RUN_DIR/$f" ] || cp "$SRC07_DIR/$f" "$RUN_DIR/$f"; done
else
  SRC05_DIR="$(find_archive_dir 05-quality-gate)" || die "sealed Pilot 002 stage-05 archive not found in $LOGS_DIR"
  SRC07_DIR="$(find_archive_dir 07-lever-screening)" || die "Pilot 003 stage-07 archive not found in $LOGS_DIR"
  copy_assert "$SRC05_DIR/frozen_set.jsonl"       "$FROZEN_JSONL"     "$FROZEN_SHA"      "frozen_set (002)"
  copy_assert "$SRC05_DIR/blind_map.jsonl"        "$BLIND_JSONL"      "$BLIND_SHA"       "blind_map (002)"
  copy_assert "$SRC05_DIR/gen_A.jsonl"            "$GENA_L40S_JSONL"  "$GENA_L40S_SHA"   "gen_A L40S historical reference (002)"
  copy_assert "$SRC07_DIR/screening_set.jsonl"    "$SCREEN_JSONL"     "$SCREEN_SHA"      "screening set (003, reused)"
  copy_assert "$SRC07_DIR/calibration_texts.jsonl" "$CALIB_TXT_JSONL" "$CALIB_TEXTS_SHA" "calibration texts (003, reused)"
fi

# ---------- phase 5: hardware-local references — gen_A (frozen 150) + gen_R (screening 40) on H100 ----------
note "5. hardware-local BF16 references on H100 (temperature 0, natural stopping, concurrency $GEN_CONC)"

generate_set() {   # $1 = items jsonl, $2 = out jsonl, $3 = label, $4 = n_items
  local items="$1" out="$2" label="$3" n="$4"
  if [ "$({ [ -f "$out" ] && wc -l < "$out"; } 2>/dev/null || echo 0)" -ge "$n" ]; then
    echo "  $label: already generated ($n rows) — resume skip"; return 0
  fi
  if [ "${STAGE10_SKIP_SERVER:-0}" != "1" ]; then
    local slog="$RUN_DIR/server_gen_${label}.log"
    echo "  starting BF16 server for $label generation"
    nohup python -m vllm.entrypoints.openai.api_server \
      --model "$MODEL" --revision "$MODEL_REV" \
      --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
      --port "$PORT" > "$slog" 2>&1 &
    echo $! > "$RUN_DIR/server.pid"
    local waited=0
    until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
      sleep 10; waited=$((waited+10))
      if [ "$waited" -ge 2400 ]; then die "$label server failed to become healthy — see $slog"; fi
      if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "$label server process died — see $slog"; fi
    done
    echo "  $label server healthy after ${waited}s"
  fi
  ITEMS_JSONL="$items" GEN_JSONL="$out" LABEL="$label" N_ITEMS="$n" \
  MODEL="$MODEL" PORT="$PORT" GEN_CONC="$GEN_CONC" GIT_REV="$GIT_REV" \
  MAX_SECONDS="$MAX_SECONDS" START_TS="$T0" python3 - <<'PY'
import asyncio, datetime, hashlib, json, os, time
import httpx

ITEMS = os.environ["ITEMS_JSONL"]; GEN = os.environ["GEN_JSONL"]
LABEL = os.environ["LABEL"]; N = int(os.environ["N_ITEMS"])
MODEL = os.environ["MODEL"]; PORT = os.environ["PORT"]; CONC = int(os.environ["GEN_CONC"])
MAX_SEC = int(os.environ["MAX_SECONDS"]); T0 = int(os.environ["START_TS"])
REQ_TO = 900.0

items = [json.loads(l) for l in open(ITEMS) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in items if r["request_id"] not in done]
print(f"  {LABEL}: {len(done)} already generated, {len(todo)} to go", flush=True)
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
            if time.time() - T0 > MAX_SEC:
                return
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
                row = dict(request_id=rec["request_id"], arm="A-bf16-h100",
                           form=rec.get("form", ""), tier_target=rec.get("tier_target", 0),
                           max_tokens=rec["max_tokens"],
                           prompt_tokens=usage.get("prompt_tokens", 0),
                           output_tokens=usage.get("completion_tokens", 0),
                           wall_s=round(wall, 3),
                           output_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                           output_text=text, model=MODEL, hardware="H100 SXM 80GB",
                           scripts_rev=os.environ["GIT_REV"],
                           ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                async with lock:
                    with open(GEN, "a") as fg:
                        fg.write(json.dumps(row, sort_keys=True) + "\n")
                    n_done += 1
                    if n_done % 10 == 0 or n_done == 1:
                        print(f"  {LABEL}: {len(done)+n_done}/{len(items)} "
                              f"(last: {rec['request_id']}, {row['output_tokens']} tok, {wall:.1f}s)", flush=True)
        await asyncio.gather(*(one(rec) for rec in todo))

asyncio.run(main())
print(f"  {LABEL} generation phase done", flush=True)
PY
  if [ "${STAGE10_SKIP_SERVER:-0}" != "1" ]; then
    [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
    sleep 5; pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
  fi
  local got_n; got_n="$({ [ -f "$out" ] && wc -l < "$out"; } 2>/dev/null || echo 0)"
  [ "$got_n" -ge "$n" ] || die "$label generation incomplete ($got_n/$n) — re-run tonight.sh to resume"
}

check_time_rail
generate_set "$FROZEN_JSONL" "$GENA_JSONL" "genA" "$N_FROZEN"
check_time_rail
generate_set "$SCREEN_JSONL" "$GENR_JSONL" "genR" "$N_SCREEN"
echo "  gen_A (H100): sha256=$(sha_file "$GENA_JSONL")"
echo "  gen_R (H100): sha256=$(sha_file "$GENR_JSONL")"

# ---------- phase 6: optional 0.5B dry-run (tooling validation; no evidence) ----------
if [ "${STAGE10_DRYRUN:-0}" = "1" ]; then
  note "6. DRY-RUN (0.5B mini pipeline — tooling validation only, produces no evidence)"
  DR_DIR="$RUN_DIR/dryrun"
  mkdir -p "$DR_DIR"
  DR_CKPT="$DR_DIR/ckpt-0.5b"
  if [ "${STAGE10_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$DR_CKPT"; echo '{"mock": true}' > "$DR_CKPT/config.json"
    echo "TEST HOOK: mock 0.5B checkpoint"
  elif [ ! -d "$DR_CKPT" ]; then
    CALIB_TXT_JSONL="$CALIB_TXT_JSONL" DR_CKPT="$DR_CKPT" DRYRUN_MODEL="$DRYRUN_MODEL" python3 - <<'PY'
import json, os, time
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_TXT_JSONL"])][:8]
from datasets import Dataset as _HFDS
import llmcompressor
from llmcompressor import oneshot
from llmcompressor.modifiers.quantization import QuantizationModifier
mods = [QuantizationModifier(targets="Linear", scheme="FP8_DYNAMIC",
                             ignore=["lm_head", "embed_tokens",
                                     "model.layers.0.self_attn.q_proj"])]
t0 = time.time()
oneshot(model=os.environ["DRYRUN_MODEL"],
        dataset=_HFDS.from_list([{"text": t} for t in calib]),
        recipe=mods, output_dir=os.environ["DR_CKPT"],
        num_calibration_samples=8, max_seq_length=512)
import sys
print(f"dry-run 0.5B checkpoint built ({round(time.time()-t0,1)}s) llmcompressor={llmcompressor.__version__}", file=sys.stderr)
PY
    [ -f "$DR_CKPT/config.json" ] || die "dry-run checkpoint incomplete (no config.json)"
  fi
  if [ "${STAGE10_SKIP_SERVER:-0}" != "1" ] && [ "${STAGE10_MOCK_BUILD:-0}" != "1" ]; then
    slog="$DR_DIR/server_dryrun.log"
    nohup python -m vllm.entrypoints.openai.api_server \
      --model "$DR_CKPT" --quantization compressed-tensors \
      --max-model-len 4096 --port "$PORT" > "$slog" 2>&1 &
    echo $! > "$RUN_DIR/server.pid"
    waited=0
    until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
      sleep 5; waited=$((waited+5))
      if [ "$waited" -ge 900 ]; then die "dry-run server failed to become healthy — see $slog"; fi
      if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "dry-run server process died — see $slog"; fi
    done
    curl -sf "http://127.0.0.1:$PORT/v1/completions" -H 'Content-Type: application/json' \
      -d "{\"model\": \"$DR_CKPT\", \"prompt\": \"Say ok.\", \"max_tokens\": 4, \"temperature\": 0}" \
      | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['choices'][0]['text'].strip(), 'empty dry-run completion'; print('dry-run completion OK')"
    kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
    sleep 3; pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
  fi
  python3 - "$DR_DIR/dryrun.json" <<'PY'
import json, sys, time
json.dump({"status": "OK", "note": "0.5B mini pipeline: oneshot build + serve + completion all green; tooling validation only, no evidence",
           "ts_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
          open(sys.argv[1], "w"), indent=2)
PY
  echo "dry-run OK (build → serve → generate chain verified on this pod)"
fi

# ---------- phase 7: anchors summary + COMPLETE ----------
note "7. anchors.json + completeness gate"
ANCHORS_JSON="$ANCHORS_JSON" RUN_DIR="$RUN_DIR" CHOSEN_JSON="$CHOSEN_JSON" \
PIP_FREEZE="$PIP_FREEZE" GIT_REV="$GIT_REV" P2_REV_RECORD="$P2_REV_RECORD" \
GPU_EXPECT="$GPU_EXPECT" python3 - <<'PY'
import hashlib, json, os
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"
RD = os.environ["RUN_DIR"]
files = {}
for name in ("frozen_set.jsonl", "blind_map.jsonl", "gen_A_L40S_reference.jsonl",
             "screening_set.jsonl", "calibration_texts.jsonl",
             "gen_A.jsonl", "gen_R.jsonl", "chosen_004.json", "pip_freeze.txt"):
    p = os.path.join(RD, name)
    if os.path.exists(p): files[name] = sha(p)
anchors = {"stage": "10-preflight-calib", "pilot": "004", "hardware": os.environ["GPU_EXPECT"] + " SXM 80GB",
           "scripts_rev": os.environ["GIT_REV"], "pilot002_rev": os.environ["P2_REV_RECORD"],
           "files": files,
           "chosen_004": json.load(open(os.environ["CHOSEN_JSON"])),
           "note": "stage-10 anchors; downstream stages consume these files by hash. No verdict is computed in this stage."}
json.dump(anchors, open(os.environ["ANCHORS_JSON"], "w"), indent=2, sort_keys=True)
print("anchors.json written")
PY

for f in "$CHOSEN_JSON" "$GENA_JSONL" "$GENR_JSONL" "$FROZEN_JSONL" "$BLIND_JSONL" "$SCREEN_JSONL" "$CALIB_TXT_JSONL" "$ANCHORS_JSON"; do
  [ -f "$f" ] || die "completeness gate: missing $f"
done
date -u > "$RUN_DIR/COMPLETE"
echo "STAGE 10 PREFLIGHT+CALIBRATION: COMPLETE"
echo "  operating point: $(python3 -c "import json; d=json.load(open('$CHOSEN_JSON')); print('D=%s C=%s fallback=%s' % (d['D'], d['C'], d.get('fallback')))")"
echo "  next: STAGE=11-arm-screening → bash tonight.sh"
exit 0
