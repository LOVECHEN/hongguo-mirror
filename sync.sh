#!/usr/bin/env bash
#
# 红果镜像同步脚本
# ---------------------------------------------------------------------------
# 作用:
#   1) 把上游【源码仓】的最新快照同步到本仓 sources/ 子目录(可在 GitHub 直接浏览)
#   2) 把上游【发布仓】的 GitHub Release 二进制资产镜像成本仓的 Releases
#   3) keepalive 心跳:防止 GitHub 因仓库 60 天无活动而自动停用定时工作流(自持)
#
# 设计原则:
#   - 二进制只在运行该脚本的机器(默认是 GitHub Actions runner)上临时流转,
#     用完即删;不会在调用者本地留下大文件。
#   - 幂等:已镜像且资产齐全的 release 自动跳过;源码无变化不产生空提交。
#   - 既能被 GitHub Actions 定时调用,也能本地手动 `bash sync.sh` 跑。
#
# 依赖: git, gh(已登录 / 或设置 GH_TOKEN), jq, rsync
# 环境变量:
#   MIRROR_REPO      目标镜像仓,默认 LOVECHEN/hongguo-mirror(Actions 里用 $GITHUB_REPOSITORY)
#   GH_TOKEN         gh 使用的 token(Actions 里注入 secrets.GITHUB_TOKEN)
#   KEEPALIVE_DAYS   距上次提交超过该天数就发心跳提交保活,默认 50(< GitHub 的 60 天阈值)
# ---------------------------------------------------------------------------
set -euo pipefail

MIRROR_REPO="${MIRROR_REPO:-LOVECHEN/hongguo-mirror}"
KEEPALIVE_DAYS="${KEEPALIVE_DAYS:-50}"

# 上游源码仓(整棵树快照进 sources/<仓名>/)
SRC_REPOS=(
  "N3urda/hongguoTV"
  "waligoraamodio288-rgb/hongguo-desktop-releases"
)
# 上游发布仓(其 GitHub Releases 的资产镜像到本仓 Releases)
RELEASE_SRC="waligoraamodio288-rgb/hongguo-desktop-releases"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
# 提交身份(固定为 mirror-bot,避免掺入其它署名)
gc() { git -c user.name="mirror-bot" -c user.email="mirror-bot@users.noreply.github.com" "$@"; }

log "镜像仓: $MIRROR_REPO"
log "本次运行时间(UTC): $(now)"
log "临时目录: $WORK"

# ===========================================================================
# 1. 源码快照同步
# ===========================================================================
# 注意:MIRROR_STATE.md 只记录上游 commit(随内容变化),不写"每次都变的运行时间戳",
#       以免每 6 小时产生一个无意义提交。最近一次运行时间看 Actions 页面即可。
MANIFEST="$ROOT/MIRROR_STATE.md"
{
  echo "# 镜像同步状态"
  echo
  echo "> 本文件仅在源码快照内容变化时更新;每次运行的时间见 GitHub Actions 运行记录。"
  echo "> keepalive 心跳状态见本仓根目录 \`.keepalive\`。"
  echo
  echo "- 目标镜像仓: \`$MIRROR_REPO\`"
  echo
  echo "## 源码快照对应的上游 commit"
  echo
} > "$MANIFEST"

for repo in "${SRC_REPOS[@]}"; do
  name="${repo##*/}"
  log "源码快照: $repo -> sources/$name"
  git clone --depth 1 "https://github.com/$repo.git" "$WORK/$name" 2>&1 | tail -1
  up_commit="$(git -C "$WORK/$name" rev-parse HEAD)"
  up_date="$(git -C "$WORK/$name" log -1 --format=%cI)"
  rm -rf "$WORK/$name/.git"
  mkdir -p "$ROOT/sources/$name"
  rsync -a --delete \
    --exclude '.mirror-upstream' \
    "$WORK/$name/" "$ROOT/sources/$name/"
  printf '%s\n' "$repo@$up_commit ($up_date)" > "$ROOT/sources/$name/.mirror-upstream"
  echo "- \`$repo\` @ \`${up_commit:0:12}\` ($up_date)" >> "$MANIFEST"
done

# 提交 & 推送源码变更
cd "$ROOT"
git add -A sources MIRROR_STATE.md
if git diff --cached --quiet; then
  log "源码快照无变化,跳过提交"
else
  gc commit -m "chore(mirror): sync source snapshot $(now)"
  git push
  log "源码快照已提交并推送"
fi

# ===========================================================================
# 2. Release 二进制镜像
# ===========================================================================
log "同步 Releases: $RELEASE_SRC -> $MIRROR_REPO"

# 兼容 bash 3.2(macOS 自带,无 mapfile):用 read 循环收集
tags=()
while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(
  gh release list --repo "$RELEASE_SRC" --limit 300 --json tagName --jq '.[].tagName')
log "上游共 ${#tags[@]} 个 release"

synced=0; updated=0; skipped=0
for tag in ${tags[@]+"${tags[@]}"}; do
  # 注意:gh release view 没有 isLatest 字段,别加(会报 Unknown JSON field 并中断)。
  meta="$(gh release view "$tag" --repo "$RELEASE_SRC" \
            --json name,body,isPrerelease,isDraft,assets)"
  [ "$(jq -r .isDraft <<<"$meta")" = "true" ] && { echo "  [$tag] draft,跳过"; continue; }

  title="$(jq -r '.name // ""' <<<"$meta")"
  prerelease_flag=""
  [ "$(jq -r .isPrerelease <<<"$meta")" = "true" ] && prerelease_flag="--prerelease"
  # 新建时一律不抢 Latest(gh 默认会把每个非预发布 release 设为 latest,导致"新→旧"
  # 顺序镜像时最旧版本抢走 Latest)。真正的 Latest 在循环结束后按上游 API 统一校正。
  latest_flag="--latest=false"
  up_assets=()
  while IFS= read -r a; do [ -n "$a" ] && up_assets+=("$a"); done < <(
    jq -r '.assets[].name' <<<"$meta")

  if [ "${#up_assets[@]}" -eq 0 ]; then
    echo "  [$tag] 上游无资产,跳过"; continue
  fi

  # 本仓已有该 release 且资产齐全 -> 跳过
  if mir_json="$(gh release view "$tag" --repo "$MIRROR_REPO" --json assets 2>/dev/null)"; then
    have=()
    while IFS= read -r h; do [ -n "$h" ] && have+=("$h"); done < <(
      jq -r '.assets[].name' <<<"$mir_json")
    missing=0
    for a in "${up_assets[@]}"; do
      printf '%s\n' ${have[@]+"${have[@]}"} | grep -qxF -- "$a" || { missing=1; break; }
    done
    if [ "$missing" = 0 ]; then
      echo "  [$tag] 已镜像且 ${#up_assets[@]} 个资产齐全,跳过"
      skipped=$((skipped+1)); continue
    fi
  fi

  # 下载上游资产到临时目录
  dldir="$WORK/rel/$tag"; mkdir -p "$dldir"
  echo "  [$tag] 下载 ${#up_assets[@]} 个资产..."
  gh release download "$tag" --repo "$RELEASE_SRC" --dir "$dldir" --clobber

  # release 说明:保留上游正文 + 镜像声明
  notes_file="$WORK/notes.md"
  {
    jq -r '.body // ""' <<<"$meta"
    printf '\n\n---\n> 由自动镜像同步自上游 release:https://github.com/%s/releases/tag/%s\n' "$RELEASE_SRC" "$tag"
  } > "$notes_file"

  if gh release view "$tag" --repo "$MIRROR_REPO" >/dev/null 2>&1; then
    echo "  [$tag] 已存在,补齐资产"
    gh release upload "$tag" --repo "$MIRROR_REPO" "$dldir"/* --clobber
    updated=$((updated+1))
  else
    echo "  [$tag] 新建 release"
    # shellcheck disable=SC2086
    gh release create "$tag" --repo "$MIRROR_REPO" \
      --title "${title:-$tag}" --notes-file "$notes_file" \
      $prerelease_flag $latest_flag "$dldir"/*
    synced=$((synced+1))
  fi
  rm -rf "$dldir"
done

log "Release 完成: 新建 $synced / 补齐 $updated / 跳过 $skipped (共 ${#tags[@]})"

# 校正 Latest:让本仓的 Latest 与上游一致(自愈,幂等)
up_latest="$(gh api "repos/$RELEASE_SRC/releases/latest" --jq .tag_name 2>/dev/null || true)"
if [ -n "${up_latest:-}" ] && gh release view "$up_latest" --repo "$MIRROR_REPO" >/dev/null 2>&1; then
  gh release edit "$up_latest" --repo "$MIRROR_REPO" --latest >/dev/null
  log "已将 $up_latest 校正为 Latest"
fi

# ===========================================================================
# 3. keepalive 心跳(自持)
# ===========================================================================
# GitHub 会在仓库连续 60 天无活动后自动停用定时(cron)工作流。
# 这里:距上次提交若已 >= KEEPALIVE_DAYS 天,就写一个心跳时间戳并提交,
# 把 60 天计时器重置。只要本工作流还在按 6 小时跑,就永远不会触及 60 天阈值 -> 自持。
cd "$ROOT"
last_epoch="$(git log -1 --format=%ct 2>/dev/null || echo 0)"
age_days=$(( ( $(date +%s) - last_epoch ) / 86400 ))
log "距上次提交 ${age_days} 天 (keepalive 阈值 ${KEEPALIVE_DAYS})"
if [ "$age_days" -ge "$KEEPALIVE_DAYS" ]; then
  log "触发 keepalive 心跳提交"
  now > "$ROOT/.keepalive"
  git add .keepalive
  gc commit -m "chore(mirror): keepalive $(now)"
  git push
else
  log "无需 keepalive"
fi

log "全部完成 ✅"
