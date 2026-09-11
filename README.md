# moon 在 stderr 断管时 abort —— 最小复现 + 回归规格

这个仓库里有**两个层次**的东西，先分清楚它们各自的作用：

| 层次 | 文件 | 依赖 | 目的 |
|---|---|---|---|
| **最小复现（MRE）** | `moon.mod` `moon.pkg` `a.mbt`（共 53 行） | **零依赖** | 让人手工复现、能直接贴进 issue |
| **可执行规格** | `cases.mbtx` `Makefile` `.github/`（共 396 行） | `moonbitlang/async@0.21.3` | 自动断言；上游修好后 CI 会转红 |

MRE 是本体（53 行），规格比本体大一个数量级（396 行）。**这不是冗余，是两个不同目的**：
前者求最短理解路径，后者求可回归。注意**复现本身不需要任何第三方依赖** ——
依赖只出现在跑断言的时候。

## 最小复现

工程只有三个文件：

| 文件 | 内容 |
|---|---|
| `moon.mod` | `name = "repro/bp"` / `version = "0.1.0"` |
| `moon.pkg` | 空（仅用于标记这是一个 package） |
| `a.mbt` | 若干未使用的私有函数 —— 只是为了产生 stderr 输出 |

一条命令：

```bash
moon check --target native 2>&1 | head -1
```

读端提前退出 → moon 下一次写 stderr 拿到 `EPIPE` → Rust 的 `eprintln!` panic →
而该二进制以 `panic = "abort"` 构建，于是普通的输出失败被升格成 `abort()`：

```
exit code 134（128 + 6）
Signal: 6 (ABRT) si_code: SI_TKILL
```

core 里的 panic 原文：

```
thread 'main' (<pid>) panicked at /rustc/59807616e1fa2540724bfbac14d7976d7e4a3860/library/std/src/io/stdio.rs:1165:9:
failed printing to stderr: Broken pipe (os error 32)
```

同一个工程上的对照：

| 写法 | exit |
|---|---|
| `2>&1 \| head -n 1` | **134** |
| `2>&1 \| head -n 3` | **134** |
| `2>&1 \| cat > /dev/null` | 0 |
| `2>&1 \| tail -n 5` | 0 |
| `> LOG 2>&1` | 0 |
| `2>&1 \| { head -n 3; cat >/dev/null; }` | 0 |

**阈值是零**：只要读端先退出，moon 的下一次 stderr 写入就失败 —— 与输出体量无关。
`a.mbt` 里放 1 个函数（约 250 字节 stderr）一样会崩，20 个只是余量。

## 跑可执行规格

```bash
make verify      # bug lane + workaround lane，本地应全绿
make bug         # 只跑命中问题 lane（顺带报 systemd core 增量）
make workaround  # 只跑绕过 lane
make fixed       # 修复验收 lane（上游修好后转 PASS）
make cases       # 列出用例
make diagnose    # 打印环境证据
```

规格是一个单文件 `.mbtx`：

```bash
moon run cases.mbtx -- verify
moon run cases.mbtx -- bug
```

它**自己开管道** —— `read_from_process()` 拿到读写两端，把写端接到子进程的
stdout/stderr，读 N 行后调用 `ReadFromProcess::close()` 关掉读端，等价于
`| head -n N` 提前退出。所以这套断言不依赖 shell 的 `|`。

`.mbtx` 的依赖要靠 registry 索引解析，**全新环境需要先同步一次索引**；
`make` 的各 lane 都依赖 `make deps`（内部 `moon update --quiet`），一般不用手动做。
离线时 `deps` 会失败但不中断，改用本地缓存继续。

## 用例

| case | harness 做的事 | 等价 shell 写法 | 自带预期 |
|---|---|---|---|
| `head-1` | 读 1 行后关读端 | `2>&1 \| head -n 1` | 134 |
| `head-3` | 读 3 行后关读端 | `2>&1 \| head -n 3` | 134 |
| `drain-all` | 读到 EOF | `2>&1 \| cat` / `\| tail -n 5` | 0 |
| `head-drain` | 读 3 行后继续抽干 | `2>&1 \| { head -n 3; cat >/dev/null; }` | 0 |
| `redirect` | stderr 写文件 | `> LOG 2>&1` | 0 |

（`pipe-cat` / `pipe-tail` 在原生管道里和 `drain-all` 是同一件事，已合并。）

## 规避

截断输出前先落盘，不要直接管道接 `head`：

```bash
moon check >/tmp/log 2>&1; head -20 /tmp/log
```

一定要边跑边看头部的话，用抽干式读端：

```bash
moon check 2>&1 | { head -n 20; cat >/dev/null; }
```

## CI

`.github/workflows/repro.yml` 三个 job 对应两组方案加一个观察位：

| job | make 目标 | 断言 |
|---|---|---|
| `hit-the-bug` | `make bug` | exit 134 |
| `workaround` | `make workaround` | exit 0 |
| `upstream-fix-status` | `make fixed` | 不再 134（`continue-on-error`） |

工具链一律装最新版，不钉版本。`hit-the-bug` 变红就是"上游已经修了"的信号 ——
那时可以撤掉绕过的写法。

## 注意

`abort` 会触发 core dump，而且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe 模式
忽略 `RLIMIT_CORE`）。反复跑 `make bug` 会让 `/var/lib/systemd/coredump` 持续增长：

```bash
sudo coredumpctl vacuum --size=50M
# 或者只删 moon 的
sudo rm /var/lib/systemd/coredump/core.moon.*
```

## 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)
Linux x86-64, systemd-coredump
```
