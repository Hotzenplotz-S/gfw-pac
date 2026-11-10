#!/usr/bin/env bash
# 把上游 zhiyi7/gfw-pac 的更新同步进本 fork 的 master，并且始终保留本地代理端口。
#
# 设计要点：
#   1) 只做 fast 合并 + 白名单冲突自动解决，其它冲突一律失败退出（不静默丢改动）。
#   2) 同步完成后强制把端口写回 LOCAL_PROXY：
#      - 改 .github/workflows/auto-generate-pac.yml 里的生成参数（否则 fork 自己的每周生成会用上游端口）
#      - 用最新数据 + 本地端口重新生成 gfw.pac
#   3) 环境变量可覆盖：UPSTREAM_REPO / UPSTREAM_BRANCH / LOCAL_PROXY / PYTHON / PUSH
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/zhiyi7/gfw-pac.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
LOCAL_PROXY="${LOCAL_PROXY:-127.0.0.1:7890}"
PYTHON="${PYTHON:-python3}"
PUSH="${PUSH:-1}"

UP="upstream/${UPSTREAM_BRANCH}"
GEN_WF=".github/workflows/auto-generate-pac.yml"
# 本地额外强制走代理的域名清单（每行一个），生成时合并进 domainsUsingProxy
LOCAL_PROXY_DOMAINS="${LOCAL_PROXY_DOMAINS:-local-proxy-domains.txt}"
# 这些文件允许被上游版本直接覆盖：gfw.pac 是生成产物，生成脚本里的端口由下面重新写回
RESOLVE_WITH_UPSTREAM="gfw.pac ${GEN_WF} cidrs-cn.txt"

git config user.name >/dev/null 2>&1 || git config user.name "github-actions[bot]"
git config user.email >/dev/null 2>&1 || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git remote add upstream "$UPSTREAM_REPO" 2>/dev/null || true
git fetch --no-tags upstream "$UPSTREAM_BRANCH"

if git merge-base --is-ancestor "$UP" HEAD; then
  echo "== master 已包含上游全部提交 =="
else
  echo "== 合并 $UP =="
  if ! git merge --no-ff --no-edit "$UP"; then
    echo "-- 冲突文件 --"
    git diff --name-only --diff-filter=U
    bad=""
    for f in $(git diff --name-only --diff-filter=U); do
      case " $RESOLVE_WITH_UPSTREAM " in
        *" $f "*)
          git checkout --theirs -- "$f"
          git add -- "$f"
          echo "   自动采用上游版本: $f"
          ;;
        *) bad="$bad $f" ;;
      esac
    done
    if [ -n "$bad" ]; then
      echo "::error::以下文件上游与本 fork 都改过，无法自动合并，请人工处理:$bad"
      git merge --abort
      exit 1
    fi
    git commit --no-edit
  fi
fi

echo "== 恢复本地端口 ${LOCAL_PROXY} =="
if [ -f "$GEN_WF" ]; then
  sed -i -E "/-p[[:space:]]+\"PROXY/ s/PROXY[[:space:]]+[^\"]+/PROXY ${LOCAL_PROXY}/" "$GEN_WF"
  if ! grep -q "PROXY ${LOCAL_PROXY}" "$GEN_WF"; then
    echo "::error::$GEN_WF 里找不到代理端口参数，上游可能改了生成流程，请人工检查"
    exit 1
  fi
fi

if [ -f gfw-pac.py ] && [ -f pac-template ]; then
  # 上游的 proxy-domains.txt 会被定期覆盖，所以本地额外域名单独放一个文件，生成时临时合并
  PROXY_DOMAINS="proxy-domains.txt"
  if [ -f "$LOCAL_PROXY_DOMAINS" ]; then
    PROXY_DOMAINS=".proxy-domains.merged.txt"
    awk 'NF && substr($0, 1, 1) != "#"' "$LOCAL_PROXY_DOMAINS" > "$PROXY_DOMAINS"
    cat proxy-domains.txt >> "$PROXY_DOMAINS"
  fi
  "$PYTHON" gfw-pac.py -f gfw.pac -p "PROXY ${LOCAL_PROXY}" \
    --proxy-domains="$PROXY_DOMAINS" \
    --direct-domains=direct-domains.txt \
    --localtld-domains=local-tlds.txt \
    --ip-file=cidrs-cn.txt
  # Windows 上 python 写文件会转成 CRLF，统一回 LF，避免整份文件被判定为改写
  sed -i 's/\r$//' gfw.pac
  if ! grep -q "var proxy = \"PROXY ${LOCAL_PROXY}\";" gfw.pac; then
    echo "::error::重新生成的 gfw.pac 端口不是 ${LOCAL_PROXY}"
    exit 1
  fi
  echo "   端口校验通过：${LOCAL_PROXY}"
  if [ "$PROXY_DOMAINS" != "proxy-domains.txt" ]; then
    rm -f "$PROXY_DOMAINS"
    if ! grep -q '"ts.net"' gfw.pac; then
      echo "::error::gfw.pac 的 domainsUsingProxy 里没有写入本地额外域名（ts.net）"
      exit 1
    fi
    echo "   本地代理域名校验通过：ts.net"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore(local): 保持代理端口 ${LOCAL_PROXY} 并重新生成 gfw.pac"
fi

if [ "$PUSH" = "1" ]; then
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
     && [ "$(git rev-list --count '@{u}..HEAD')" -eq 0 ]; then
    echo "== 没有需要推送的内容 =="
  else
    git push origin "HEAD:${UPSTREAM_BRANCH}" || {
      echo "推送被拒绝（可能有并发提交），rebase 后重试一次"
      git pull --rebase origin "$UPSTREAM_BRANCH"
      git push origin "HEAD:${UPSTREAM_BRANCH}"
    }
  fi
fi