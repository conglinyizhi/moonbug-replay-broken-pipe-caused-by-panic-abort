#!/usr/bin/env bash
# 最小复现：moon 写 stderr 撞上 EPIPE 时 abort（SIGABRT / exit 134）
set -u
cd "$(dirname "$0")"
MOON="${MOON:-$HOME/.moon/bin/moon}"

echo "== moon 版本 =="
"$MOON" version

echo
echo "== [1] 安全：重定向到文件 =="
"$MOON" check --target native >/tmp/moonbug.log 2>&1
echo "exit=$?   stderr 输出 $(wc -c </tmp/moonbug.log) 字节"

echo
echo "== [2] 安全：完整消费输出 =="
"$MOON" check --target native 2>&1 | cat >/dev/null
echo "exit=${PIPESTATUS[0]}"

echo
echo "== [3] 崩溃：读端提前退出 =="
"$MOON" check --target native 2>&1 | head -1 >/dev/null
echo "exit=${PIPESTATUS[0]}    # 期望 134 == 128 + 6 (SIGABRT)"

echo
echo "== [4] 崩溃后 systemd 记录的 core =="
pid=$(coredumpctl list --no-pager 2>/dev/null | grep '/\.moon/bin/moon' | tail -1 | awk '{print $5}')
if [ -n "${pid:-}" ]; then
  echo "最新 moon core pid=$pid"
  coredumpctl info "$pid" --no-pager 2>/dev/null | grep -E "Signal:|Command Line:"
else
  echo "未找到 moon core（coredumpctl 不可用或无记录）"
fi
