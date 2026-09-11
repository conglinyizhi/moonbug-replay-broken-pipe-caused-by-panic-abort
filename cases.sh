#!/usr/bin/env bash
# moon broken-pipe abort —— 用例集
#
#   cases.sh list           列出用例及其自带预期
#   cases.sh run <case>     跑单个用例，按自带预期断言（退出 0 = PASS）
#   cases.sh lane <name>    跑整条 lane：bug | workaround | fixed
#   cases.sh corecount      打印 systemd 里 moon core 数量（无 coredumpctl 时输出 0）
#
# 环境变量：MOON（moon 可执行文件）、TARGET（native/js）、LOG（重定向用日志）
set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [ ! -f "$REPO_DIR/moon.mod" ]; then
  echo "cases.sh: 找不到工程根（$REPO_DIR 下没有 moon.mod）" >&2
  exit 2
fi
MOON="${MOON:-$HOME/.moon/bin/moon}"
TARGET="${TARGET:-native}"
LOG="${LOG:-/tmp/moonbug-replay.log}"

RC=0

# --- 用例：只负责跑一次 moon，把 exit code 写进 RC ---
# 命中：读端提前退出 -> moon 写 stderr 拿 EPIPE -> panic -> abort
case_head_1()     { "$MOON" check --target "$TARGET" 2>&1 | head -n 1 >/dev/null;            RC=${PIPESTATUS[0]}; }
case_head_3()     { "$MOON" check --target "$TARGET" 2>&1 | head -n 3 >/dev/null;            RC=${PIPESTATUS[0]}; }
# 绕过：读端不提前退出
case_redirect()   { "$MOON" check --target "$TARGET" >"$LOG" 2>&1;                            RC=$?; }
case_pipe_cat()   { "$MOON" check --target "$TARGET" 2>&1 | cat >/dev/null;                   RC=${PIPESTATUS[0]}; }
case_pipe_tail()  { "$MOON" check --target "$TARGET" 2>&1 | tail -n 5 >/dev/null;             RC=${PIPESTATUS[0]}; }
case_head_drain() { "$MOON" check --target "$TARGET" 2>&1 | { head -n 3 >&2; cat >/dev/null; }; RC=${PIPESTATUS[0]}; }

# 名字|函数|自带预期|管道写法
CASES=(
  "head-1|case_head_1|134|2>&1 | head -n 1"
  "head-3|case_head_3|134|2>&1 | head -n 3"
  "redirect|case_redirect|0|> LOG 2>&1"
  "pipe-cat|case_pipe_cat|0|2>&1 | cat > /dev/null"
  "pipe-tail|case_pipe_tail|0|2>&1 | tail -n 5"
  "head-drain|case_head_drain|0|2>&1 | { head -n 3; cat >/dev/null; }"
)

lookup() {
  local want="$1" e
  for e in "${CASES[@]}"; do
    [ "${e%%|*}" = "$want" ] && { printf '%s' "$e"; return 0; }
  done
  return 1
}

do_assert() {  # do_assert <case> <eq|ne> <code>
  local name="$1" op="$2" want="$3" e n f exp desc ok=0
  if ! e="$(lookup "$name")"; then echo "unknown case: $name" >&2; return 2; fi
  IFS='|' read -r n f exp desc <<<"$e"
  "$f"
  printf '  %-11s %-34s exit=%-4s ' "$n" "$desc" "$RC"
  if [ "$op" = eq ] && [ "$RC" = "$want" ]; then ok=1; fi
  if [ "$op" = ne ] && [ "$RC" != "$want" ]; then ok=1; fi
  if [ "$ok" = 1 ]; then echo "PASS"; else echo "FAIL (期望 $op $want)"; fi
  return $((1-ok))
}

lane() {
  local fail=0 e n f exp desc
  case "${1:-}" in
    bug)
      echo "命中问题 lane —— 期望 exit 134（128 + 6 SIGABRT）"
      do_assert head-1 eq 134 || fail=1
      do_assert head-3 eq 134 || fail=1
      ;;
    workaround)
      echo "绕过 lane —— 期望 exit 0（读端不提前退出，不产生 EPIPE）"
      for e in "${CASES[@]}"; do
        IFS='|' read -r n f exp desc <<<"$e"
        [ "$exp" = 0 ] || continue
        do_assert "$n" eq 0 || fail=1
      done
      ;;
    fixed)
      echo "修复验收 lane —— 期望不再 abort（上游修好后转 PASS，现在是预期 FAIL）"
      do_assert head-1 ne 134 || fail=1
      ;;
    *)
      echo "unknown lane: ${1:-}" >&2; return 2
      ;;
  esac
  return $fail
}

cd "$REPO_DIR"

case "${1:-}" in
  list)
    printf '%-12s %-6s %s\n' CASE EXPECT "管道写法"
    for e in "${CASES[@]}"; do
      IFS='|' read -r n f exp desc <<<"$e"
      printf '%-12s %-6s %s\n' "$n" "$exp" "$desc"
    done
    ;;
  run)
    if ! e="$(lookup "${2:-}")"; then echo "unknown case: ${2:-}" >&2; exit 2; fi
    IFS='|' read -r n f exp desc <<<"$e"
    do_assert "$n" eq "$exp"
    ;;
  lane)
    lane "${2:-}"
    ;;
  corecount)
    if command -v coredumpctl >/dev/null 2>&1; then
      coredumpctl list --no-pager 2>/dev/null | grep -c '/\.moon/bin/moon' || true
    else
      echo 0
    fi
    ;;
  *)
    sed -n '2,9p' "$0" >&2
    exit 2
    ;;
esac
