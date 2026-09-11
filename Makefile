# moon 在 stderr 断管时 abort —— 用 .mbtx 驱动，几乎不靠 shell

SHELL  := /bin/bash
MOON   ?= $(HOME)/.moon/bin/moon
FIX_CC ?= gcc

export MOON FIX_CC

# MOON_CC 是给「编译这个 .mbtx 自己」用的。
# 复现用的 moon check 不需要编译器，所以子进程环境里不带它。
RUN = MOON_CC="$(FIX_CC)" "$(MOON)" run --target native cases.mbtx --

.PHONY: help all deps verify bug workaround fixed cases diagnose clean

help:
	@printf '%s\n' \
	  'moon stderr 断管 → SIGABRT（.mbtx 驱动，原生管道）' \
	  '' \
	  '  make verify      命中问题 lane + 绕过 lane，本地应全绿' \
	  '  make bug         命中问题 lane：关读端 → exit 134，并报 core 增量' \
	  '  make workaround  绕过 lane：读干 / 落盘 → exit 0' \
	  '  make fixed       修复验收 lane：关读端也不再 abort（上游修好后转 PASS）' \
	  '  make cases       列出用例' \
	  '  make diagnose    打印环境证据' \
	  '  make deps        同步 registry 索引（首次运行需要）' \
	  '  make clean       清掉 _build' \
	  '' \
	  '直接跑： $(RUN) <子命令>' \
	  "变量： MOON=$(MOON)   FIX_CC=$(FIX_CC)"

all: verify

# .mbtx 的依赖（moonbitlang/async）要靠 registry 索引解析；全新环境里索引是空的，
# 需要先同步一次。同步失败不致命 —— 可能离线，此时改用本地缓存继续。
deps:
	@$(MOON) update --quiet || echo "warn: moon update 失败（可能离线），改用本地缓存"

verify: deps
	@$(RUN) verify

bug: deps
	@$(RUN) bug

workaround: deps
	@$(RUN) workaround

fixed: deps
	@$(RUN) fixed

cases: deps
	@$(RUN) list

diagnose: deps
	@$(RUN) diagnose

clean:
	@rm -rf _build
	@echo 'cleaned: _build'
