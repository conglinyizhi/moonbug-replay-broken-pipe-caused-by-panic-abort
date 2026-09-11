# moon broken-pipe abort —— 复现 / 绕过 / 修复验收
#
#   moon 在 stderr 管道读端提前退出时拿到 EPIPE，Rust 的 eprintln! 会 panic；
#   而该二进制以 panic=abort 构建，于是普通的输出失败被升格成 abort()：
#     exit 134 / Signal: 6 (ABRT) si_code: SI_TKILL / 每次留下一个 core
#
#   证据（core 内 panic 原文）：
#     failed printing to stderr: Broken pipe (os error 32)
#
#   本 Makefile 就是那条线的可执行规格：一条 lane 去撞它，一条 lane 绕它。

SHELL  := /bin/bash
MOON   ?= $(HOME)/.moon/bin/moon
TARGET ?= native
LOG    ?= /tmp/moonbug-replay.log

export MOON TARGET LOG

.PHONY: help all verify bug workaround fixed cases cores clean

help:
	@printf '%s\n' \
	  'moon broken-pipe abort —— 复现 / 绕过 / 修复验收' \
	  '' \
	  '  make verify      bug lane + workaround lane，本地应全绿' \
	  '  make bug         命中问题 lane：断言 exit 134（128 + 6 SIGABRT）' \
	  '  make workaround  绕过 lane：断言 exit 0（不触发 EPIPE）' \
	  '  make fixed       修复验收 lane：上游修好后才 PASS（当前预期 FAIL）' \
	  '  make cases       列出用例及其自带预期' \
	  '  make cores       打印最近一次 moon core 的签名与 panic 文本' \
	  '  make clean       清掉 _build 与日志' \
	  '' \
	  "变量： MOON=$(MOON)   TARGET=$(TARGET)   LOG=$(LOG)"

all: verify

# bug lane 每跑一次就多一个 core，所以顺带报一下增量
verify: bug workaround

bug:
	@before=$$(./cases.sh corecount); \
	 ./cases.sh lane bug; rc=$$?; \
	 after=$$(./cases.sh corecount); \
	 echo "  systemd core 计数: $$before -> $$after"; \
	 exit $$rc

workaround:
	@./cases.sh lane workaround

fixed:
	@./cases.sh lane fixed

cases:
	@./cases.sh list

cores:
	@if ! command -v coredumpctl >/dev/null 2>&1; then echo '本机没有 coredumpctl，跳过'; exit 0; fi; \
	 pid=$$(coredumpctl list --no-pager 2>/dev/null | grep '/\.moon/bin/moon' | tail -1 | awk '{print $$5}'); \
	 if [ -z "$$pid" ]; then echo '没有 moon core 记录'; exit 0; fi; \
	 echo "最近一次 moon core: pid=$$pid"; \
	 coredumpctl info "$$pid" --no-pager 2>/dev/null | grep -E 'Signal:|Command Line:'; \
	 echo '--- core 内 panic 文本 ---'; \
	 tmp=$$(mktemp); \
	 if coredumpctl dump "$$pid" -o "$$tmp" >/dev/null 2>&1; then \
	   strings -n 8 "$$tmp" | grep -m1 'panicked at'; \
	   strings -n 8 "$$tmp" | grep -m1 'failed printing'; \
	 else \
	   echo '(dump 失败，可能需要 sudo)'; \
	 fi; \
	 rm -f "$$tmp"

clean:
	@rm -rf _build
	@rm -f "$(LOG)"
	@echo 'cleaned: _build $(LOG)'
