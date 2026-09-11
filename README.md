# moon 在 stderr 断管时 abort（SIGABRT）

## 1. 这个 bug 是什么

### 原因

`moon` 是 Rust 写的构建工具，而且**以 `panic = "abort"` 构建** ——
这条是实测的，不是推测：`moon` 没有链接 `libgcc_s`/`libunwind`（同机的 `rustc`、`cargo`
都链接了），而且观测到的是 **SIGABRT** 而不是 Rust 默认的 `exit 101`。当它往 stderr 写输出、
而管道读端已经退出时，会走成这样：

1. `write` 返回 `EPIPE`
2. Rust 的 `println!` / `eprintln!` 遇到这类错误**不返回 `Err`，而是直接 panic**
3. `panic = "abort"` 把这个 panic 变成 `abort()`

于是「输出失败」被升格为「进程被信号杀死」：

```
exit code 134（128 + 6）
Signal: 6 (ABRT) si_code: SI_TKILL
```

core 里的 panic 原文：

```
thread 'main' (<pid>) panicked at /rustc/59807616e1fa2540724bfbac14d7976d7e4a3860/library/std/src/io/stdio.rs:1165:9:
failed printing to stderr: Broken pipe (os error 32)
```

**阈值是零**：只要读端先退出，moon 的下一次 stderr 写入就失败 —— 与输出体量无关。

### 复现平台

| 平台 | moon 版本 | 结果 |
|---|---|---|
| 本机 Linux x86-64（systemd-coredump） | 0.1.20260907（7aabba5，2026-09-07） | 复现，3/3 确定性 |
| GitHub Actions `ubuntu-24.04` | 0.1.20260904（94521db，2026-09-04） | 复现（`hit-the-bug` job 绿） |

与 moon 版本、项目内容都无关：触发条件是**调用方怎么接输出**，不是编译什么。

## 2. 快速复现

### 最少需要什么

三个文件，加一条命令：

| 文件 | 内容 |
|---|---|
| `moon.mod` | `name = "repro/bp"` / `version = "0.1.0"` |
| `moon.pkg` | 空（仅用于标记这是一个 package） |
| `a.mbt` | 20 个未使用的私有函数 —— 只是为了产生 stderr 输出 |

```bash
moon check --target native 2>&1 | head -1
```

`head -1` 读完第一行就退出 → 读端关闭 → moon 继续往 stderr 写 → `EPIPE` → abort。
期望 `exit 134`（用 `echo ${PIPESTATUS[0]}` 看管道首段的退出码）。

### 文件清单：哪些和这个 bug 有关

| 文件 | 行数 | 和 bug 的关系 |
|---|---|---|
| `moon.mod` | 3 | **必需** —— 标记这是一个 moon 模块 |
| `moon.pkg` | 0 | **必需** —— 标记这是一个 package |
| `a.mbt` | 50 | **必需** —— 产生 stderr 输出。1 个函数（约 250 字节）就够，20 个只是余量 |
| `cases.mbtx` | 275 | **与 bug 无关** —— 可执行规格，负责断言 |
| `Makefile` | 58 | **与 bug 无关** —— 调用规格的入口 |
| `.github/workflows/repro.yml` | 60 | **与 bug 无关** —— CI |
| `README.md` | 140 | **与 bug 无关** —— 本文档 |

**把后四行删掉，bug 照样复现**：只要那三个文件 + `moon check | head -1`。
规格存在的意义是「自动断言、上游修好后能报警」，不是「复现」。

## 3. 其他

### 对照：什么写法会中招

| 写法 | exit |
|---|---|
| `2>&1 \| head -n 1` | **134** |
| `2>&1 \| head -n 3` | **134** |
| `2>&1 \| cat > /dev/null` | 0 |
| `2>&1 \| tail -n 5` | 0 |
| `> LOG 2>&1` | 0 |
| `2>&1 \| { head -n 3; cat >/dev/null; }` | 0 |

### 可执行规格

单文件 `.mbtx`：`moon run cases.mbtx -- <子命令>`，没有 `cases.sh`、没有 `repro.sh`。
它**自己开管道** —— `read_from_process()` 拿到读写两端，把写端接到子进程的
stdout/stderr，读 N 行后调 `ReadFromProcess::close()` 关掉读端，等价于 `| head -n N`
提前退出。所以这套断言不依赖 shell 的 `|`。

```bash
make verify      # bug lane + workaround lane，本地应全绿
make bug         # 只跑命中问题 lane（顺带报 systemd core 增量）
make workaround  # 只跑绕过 lane
make fixed       # 修复验收 lane（上游修好后转 PASS）
make cases       # 列出用例
make diagnose    # 环境证据
make deps        # 同步 registry 索引（首次运行需要，各 lane 会自动先跑）
```

`.mbtx` 的依赖（`moonbitlang/async@0.21.3`）要靠 registry 索引解析，全新环境需要先
同步一次；离线时 `deps` 会失败但不中断，改用本地缓存继续。
**注意：复现本体零依赖，依赖只出现在跑断言的时候。**

### 用例

| case | harness 做的事 | 等价 shell 写法 | 自带预期 |
|---|---|---|---|
| `head-1` | 读 1 行后关读端 | `2>&1 \| head -n 1` | 134 |
| `head-3` | 读 3 行后关读端 | `2>&1 \| head -n 3` | 134 |
| `drain-all` | 读到 EOF | `2>&1 \| cat` / `\| tail -n 5` | 0 |
| `head-drain` | 读 3 行后继续抽干 | `2>&1 \| { head -n 3; cat >/dev/null; }` | 0 |
| `redirect` | stderr 写文件 | `> LOG 2>&1` | 0 |

### CI

三个 job：`hit-the-bug`（断言 134）/ `workaround`（断言 0）/
`upstream-fix-status`（允许失败，用来观察上游什么时候修好）。
工具链一律装最新版，不钉版本。`hit-the-bug` 变红就是「上游已经修了」的信号。

### 规避

截断输出前先落盘，不要直接管道接 `head`：

```bash
moon check >/tmp/log 2>&1; head -20 /tmp/log
```

一定要边跑边看头部，就用抽干式读端：

```bash
moon check 2>&1 | { head -n 20; cat >/dev/null; }
```

### 注意

`abort` 会触发 core dump，而且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe 模式
忽略 `RLIMIT_CORE`）。反复跑 `make bug` 会让 `/var/lib/systemd/coredump` 持续增长：

```bash
sudo coredumpctl vacuum --size=50M
sudo rm /var/lib/systemd/coredump/core.moon.*
```

### 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)
Linux x86-64, systemd-coredump
```

### 相关上游 issue

| issue | 关系 |
|---|---|
| [moonbitlang/moon#472](https://github.com/moonbitlang/moon/issues/472) `Panic with println on pipeline` | **同一类问题**（`failed printing to ... Broken pipe`，行号 `1118` = stdout，本仓库的是 `1165` = stderr）。2025-12-01 以 **stale 关闭，不是修复** —— 维护者原话：*"If this issue still exists, please reopen."* 本仓库就是「仍然存在」的证据 |
| [moonbitlang/moon#852](https://github.com/moonbitlang/moon/issues/852) `Node in moon test/moon run changed stderr to non-blocking` | **不是同一条路径**。那条结的是 `EAGAIN`（os error 35，非阻塞），维护者当时的结论是 *"We can't fix it in moon itself"*。本仓库是 `EPIPE`（os error 32，断管）—— 这个在 moon 侧**可以**处理（显式处理写错误 / 装 panic hook / 忽略 EPIPE），两者不要混为一谈 |

目标仓库：**[moonbitlang/moon](https://github.com/moonbitlang/moon)**（Rust 写的构建工具）。
注意 `moonbitlang/moonbit-compiler` 的 issue 是**关闭**的，发不进去。
