#!/usr/bin/env bash
# =====================================================================
# tonight.sh — Effiq Pilot 004 pod runner (hands-only entry point)
#
# 操作员唯一入口（点火标准姿势，终端可随意关闭）：
#     nohup bash tonight.sh > tonight.out 2>&1 &
#
# 行为：
#   1. 克隆或更新两个仓库（克隆即内嵌凭证，推送不再交互卡死）：
#      - effiq/pilot004  （脚本与配置的唯一来源）
#      - effiq/pilot-logs（证据链归档，stage 脚本的 LOGS_DIR）
#   2. 读取 pilot004 仓库内 STAGE 文件，运行对应 stage 脚本。
#   3. stage 收尾（exit 0 = PASS 路径完整；exit 2 = 科学 FAIL 但流程完整）
#      后：泄漏扫描 → 提交并推送 pilot-logs（证据先行）与 pilot004（若脏）。
#      命中任一泄漏模式 = 拒绝推送。
#
# 私有件纪律（三层披露制）：
#   - ~/pilot-env/arms-recipes.json（闸门层完整配方）永不进仓库；
#   - ~/pilot-env/openrouter-key、github.token 永不进仓库、永不发给 AI；
#   - $CKPT_ROOT/recipes-local.jsonl（配方全文本地副本）永不被推送；
#   - 若挂了网络卷（VOLUME_DIR，默认 /workspace）：私有件与配方本地账
#     每次收尾同步一份到卷上（pod 全抹可重建）。
#
# 成本纪律（2026-10-10 新规）：本脚本与 stage 脚本不写任何金额进公开制品。
#
# 本脚本是公开件：按"必然泄露"标准书写，不含任何秘密。
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/effiq/pilot004.git"
LOGS_URL="https://github.com/effiq/pilot-logs.git"
EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
REPO_DIR="$EFFIQ_HOME/pilot004"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
ENV_DIR="$HOME/pilot-env"
TOKEN_FILE="$ENV_DIR/github.token"
STAGE_FILE="$REPO_DIR/STAGE"
VOLUME_DIR="${VOLUME_DIR:-/workspace}"   # 网络卷（004 起强制；沙箱可指向任意可写目录）

say() { echo "[tonight $(date -u +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# ---------- 0. 私有件在位检查（不读内容，只查存在与权限） ----------
[ -f "$TOKEN_FILE" ] || die "missing $TOKEN_FILE (GitHub PAT, chmod 600)"
[ -f "$ENV_DIR/openrouter-key" ] || die "missing $ENV_DIR/openrouter-key"
[ -f "$ENV_DIR/arms-recipes.json" ] || die "missing $ENV_DIR/arms-recipes.json (私有配方文件，未就位不能开工)"
for f in "$TOKEN_FILE" "$ENV_DIR/openrouter-key" "$ENV_DIR/arms-recipes.json"; do
  perm=$(stat -c '%a' "$f")
  [ "$perm" = "600" ] || die "$f permission is $perm, must be 600: chmod 600 $f"
done
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")

# ---------- 1. 克隆或更新仓库（克隆即内嵌凭证） ----------
mkdir -p "$EFFIQ_HOME"
clone_or_pull() {   # $1 = url, $2 = dir
  local url="$1" dir="$2"
  if [ ! -d "$dir/.git" ]; then
    say "cloning $url (token-embedded)"
    git clone "https://x-access-token:${TOKEN}@${url#https://}" "$dir"
  else
    say "pulling latest in $dir"
    # 历史克隆若未内嵌凭证，原地修复 remote（防交互卡死）
    git -C "$dir" remote set-url origin "https://x-access-token:${TOKEN}@${url#https://}"
    git -C "$dir" fetch origin
    # addendum A2 (2026-10-12): never wipe unpushed local state — halt loudly instead
    if [ -n "$(git -C "$dir" status --porcelain)" ] || [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse origin/main)" ]; then
      die "LOCAL UNPUSHED STATE in $dir — refusing reset --hard (addendum A2). Push or clean manually, then re-run."
    fi
    git -C "$dir" reset --hard origin/main
  fi
}
clone_or_pull "$REPO_URL" "$REPO_DIR"
clone_or_pull "$LOGS_URL" "$LOGS_DIR"

[ -f "$STAGE_FILE" ] || die "STAGE file missing in repo"
STAGE=$(tr -d '[:space:]' < "$STAGE_FILE")
[ -n "$STAGE" ] || die "STAGE file empty"
SCRIPT="$REPO_DIR/stages/$STAGE.sh"
[ -f "$SCRIPT" ] || die "stage script not found: stages/$STAGE.sh"
say "STAGE=$STAGE"

# ---------- 2. 运行 stage ----------
set +e
bash "$SCRIPT"
rc=$?
set -e
say "stage exit code: $rc"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  say "stage did not complete (rc=$rc); checkpoint saved; re-run tonight.sh to resume"
  exit "$rc"
fi

# ---------- 3. 泄漏扫描（推送前硬闸；两仓都扫） ----------
scan_repo() {   # $1 = repo dir
  local repo="$1" hits=0
  local patterns='ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{40,}'
  if git -C "$repo" grep -nI -E "$patterns" -- . ':(exclude).git' >/dev/null 2>&1; then
    echo "LEAK SCAN [$repo]: token-pattern hits:" >&2
    git -C "$repo" grep -nI -E "$patterns" -- . ':(exclude).git' | head -20 >&2 || true
    hits=1
  fi
  if git -C "$repo" ls-files | grep -E '(^|/)arms-recipes\.json$|recipes-local\.jsonl$|(^|/)profile\.json$' >/dev/null 2>&1; then
    echo "LEAK SCAN [$repo]: private recipe/profile file tracked:" >&2
    git -C "$repo" ls-files | grep -E '(^|/)arms-recipes\.json$|recipes-local\.jsonl$|(^|/)profile\.json$' >&2 || true
    hits=1
  fi
  # 配方参数指纹（stages/ 与 tonight.sh 是公开件，类名合法；查的是数据文件本体；jsonl 为数据文件豁免——addendum A2）
  if git -C "$repo" grep -nI -E '"smoothing_strength"|"scheme_overrides"|"kv_cache_scheme"|"top_k"|"theta_mult"|"mse_rel"' \
       -- . ':(exclude).git' ':(exclude)stages/' ':(exclude)tonight.sh' ':(exclude)*.jsonl' >/dev/null 2>&1; then
    echo "LEAK SCAN [$repo]: private recipe/profile fingerprints outside stages/:" >&2
    git -C "$repo" grep -nI -E '"smoothing_strength"|"scheme_overrides"|"kv_cache_scheme"|"top_k"|"theta_mult"|"mse_rel"' \
       -- . ':(exclude).git' ':(exclude)stages/' ':(exclude)tonight.sh' ':(exclude)*.jsonl' | head -20 >&2 || true
    hits=1
  fi
  # 成本纪律：公开制品不含美元金额（$ 后随数字的货币形态）
  # addendum A4 (2026-10-12): 美元扫描只覆盖本次推送新增的行（staged diff）。
  # 规则生效前已公开的历史无法收回，闸门的职责是拦住新泄漏，不是审判历史——
  # 整树扫描误伤了规则诞生前就已公开的旧日志（stage-11 推送被拦事件）。
  local dollar_hits
  dollar_hits=$(git -C "$repo" diff --cached -U0 -- . ':(exclude).git' ':(exclude)stages/' \
      ':(exclude)tonight.sh' ':(exclude)*.jsonl' 2>/dev/null \
    | grep -E '^\+' | grep -vE '^\+\+\+' | grep -E '\$[0-9]+\.?[0-9]*' | head -20 || true)
  if [ -n "$dollar_hits" ]; then
    echo "LEAK SCAN [$repo]: dollar-figure pattern in newly-added lines (cost secrecy rule 2026-10-10; addendum A4):" >&2
    echo "$dollar_hits" >&2
    hits=1
  fi
  return "$hits"
}

push_repo() {   # $1 = repo dir, $2 = label
  local repo="$1" label="$2"
  cd "$repo"
  git add -A
  if git diff --cached --quiet; then
    say "$label: nothing new to commit"
    return 0
  fi
  if ! scan_repo "$repo"; then
    die "LEAK SCAN FAILED in $label — refusing to push. Inspect hits above, clean, re-run."
  fi
  local msg="pilot004 $STAGE artifacts $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$rc"
  git -c user.name="effiq-pod" -c user.email="pod@effiq.invalid" commit -m "$msg" >/dev/null
  git push origin HEAD:main
  say "$label pushed: $msg"
}

# 证据先行：pilot-logs 是判决书与原始日志的家
push_repo "$LOGS_DIR" "pilot-logs"
push_repo "$REPO_DIR" "pilot004"

# ---------- 4. 网络卷私有件备份（pod 全抹可重建；不上任何远端） ----------
if [ -d "$VOLUME_DIR" ] && [ -w "$VOLUME_DIR" ]; then
  mkdir -p "$VOLUME_DIR/pilot-env-backup"
  cp -p "$ENV_DIR/arms-recipes.json" "$VOLUME_DIR/pilot-env-backup/arms-recipes.json" 2>/dev/null || true
  CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p004-ckpt}"
  [ -f "$CKPT_ROOT/recipes-local.jsonl" ] && cp -p "$CKPT_ROOT/recipes-local.jsonl" "$VOLUME_DIR/pilot-env-backup/" || true
  [ -f "$CKPT_ROOT/profile.json" ] && cp -p "$CKPT_ROOT/profile.json" "$VOLUME_DIR/pilot-env-backup/" || true
  chmod 600 "$VOLUME_DIR/pilot-env-backup/"* 2>/dev/null || true
  say "private-file backup synced to volume ($VOLUME_DIR/pilot-env-backup/)"
else
  say "WARNING: no writable volume at $VOLUME_DIR — private files live on this pod only"
fi

unset TOKEN
say "done (stage rc=$rc)"
exit 0
