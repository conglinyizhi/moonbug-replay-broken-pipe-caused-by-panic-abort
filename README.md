# moon-broken-pipe-abort

`moon` 往 stderr 写输出时，如果管道读端已经退出，write 会拿到 `EPIPE`。
Rust 的 `println!` / `eprintln!` 遇到这类错误不是返回 `Err`，而是直接 panic；
而该二进制以 `panic = "abort"` 构建，于是普通的「输出失败」被升格成 `abort()`。

## 现象

- 退出码 `134`（`128 + 6`）
- systemd 记录：`Signal: 6 (ABRT) si_code: SI_TKILL`
- 每次留下一个 core

core 里的 panic 原文：

```
thread 'main' (<pid>) panicked at /rustc/59807616e1fa2540724bfbac14d7976d7e4a3860/library/std/src/io/stdio.rs:1165:9:
failed printing to stderr: Broken pipe (os error 32)
```

## 本地

```bash
make            # 列出所有目标
make verify     # bug lane + workaround lane，本地应全绿
make bug        # 命中问题 lane
make workaround # 绕过 lane
make fixed      # 修复验收 lane（上游修好后才会 PASS）
make cores      # 打印最近一次 moon core 的签名与 panic 文本
```

harness 是一个单文件 `.mbtx`：`moon run cases.mbtx -- <子命令>`，
没有 `cases.sh`，也没有 `repro.sh`。它**自己开管道**：给子进程的 stdout/stderr 接上
一根管道，读几行后把**读端关掉**，等价于 `| head -n N` 提前退出 ——
这样复现机制不再依赖 shell 的 `|`。

```bash
moon run cases.mbtx -- verify
moon run cases.mbtx -- bug
```

harness 用 `moonbitlang/async@0.21.3` 的 process API（`read_from_process` /
`ReadFromProcess::close`）。因为 `.mbtx` 的依赖要靠 registry 索引解析，
**全新环境需要先同步一次索引**；`make` 的各 lane 都依赖 `make deps`
（内部 `moon update --quiet`），所以一般不用手动做。离线时 `deps` 会失败但不中断。

## 用例

| case | harness 做的事 | 等价 shell 写法 | 自带预期 |
|---|---|---|---|
| `head-1` | 读 1 行后关读端 | `2>&1 \| head -n 1` | 134 |
| `head-3` | 读 3 行后关读端 | `2>&1 \| head -n 3` | 134 |
| `drain-all` | 读到 EOF | `2>&1 \| cat` / `\| tail -n 5` | 0 |
| `head-drain` | 读 3 行后继续抽干 | `2>&1 \| { head -n 3; cat >/dev/null; }` | 0 |
| `redirect` | stderr 写文件 | `> LOG 2>&1` | 0 |

（原来的 `pipe-cat` / `pipe-tail` 在原生管道里和 `drain-all` 是同一件事，已合并。）

阈值是零：只要读端先退出，moon 的下一次 stderr 写入就失败。
输出体量无关 —— `a.mbt` 只留 1 个未使用函数（stderr 258 字节）同样崩。

`head-drain` 是唯一既能看到头部、又不会把 moon 弄死的写法：`head` 打完前几行后
继续 `cat >/dev/null` 把剩下的抽干，读端不提前退出，就没有 EPIPE。

## 工程

`moon.mod` + 空的 `moon.pkg` + `a.mbt`（3000 个未使用的私有函数，用来产生 stderr 输出）。
减少函数数量不影响复现。

## CI

`.github/workflows/repro.yml` 三个 job 对应三组方案：

| job | make 目标 | 断言 |
|---|---|---|
| `hit-the-bug` | `make bug` | exit 134 |
| `workaround` | `make workaround` | exit 0 |
| `upstream-fix-status` | `make fixed` | 不再 134（`continue-on-error`） |

- 工具链一律装最新版，不钉版本 —— 上游要复现这个 bug 有的是办法，这里不必替他们固定环境。
- 前两个 job 是硬断言：`hit-the-bug` 若是绿的，说明当前版本确实会 abort；
  一旦上游修了它会变红 —— 那就是撤掉 workaround 的信号。
- `upstream-fix-status` 反过来，允许失败，专门用来观察上游什么时候修好。
- runner 上也有 systemd-coredump：实测 `make bug` 会记到 core 增量（日志里
  `systemd core 计数` 从 0 变 2）。断言本身只看退出码，core 只是佐证。

## 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)   # feature flags: rr_moon_mod, rr_moon_pkg
Linux x86-64, systemd-coredump, glibc
```

## 规避

截断输出前先落盘，不要直接管道接 `head`：

```bash
moon check >/tmp/log 2>&1; head -20 /tmp/log
```

一定要边跑边看头部的话，用抽干式读端：

```bash
moon check 2>&1 | { head -n 20; cat >/dev/null; }
```

## 注意

`abort` 会触发 core dump，而且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe
模式忽略 RLIMIT_CORE）。本机反复跑 `make bug` 会让 `/var/lib/systemd/coredump`
持续增长，清理：

```bash
sudo coredumpctl vacuum --size=50M
# 或者只删 moon 的
sudo rm /var/lib/systemd/coredump/core.moon.*
```
