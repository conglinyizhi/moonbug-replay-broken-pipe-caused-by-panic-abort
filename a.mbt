///|
/// 这个文件不参与任何逻辑。它存在的唯一目的：让 moon 往 stderr 输出足够多的
/// warning（每个未使用的私有函数一条），从而保证读端关闭之后 moon 仍有内容要写 ——
/// 那一下写入就是 EPIPE 的触发点。
///
/// 实测 1 个函数（约 250 字节 stderr）就足以复现；这里留 20 个作为余量，
/// 不想让复现今依赖 moon 内部把输出切成几次 write。
///
/// 复现步骤见 README 的「最小复现」一节。

///|
fn f00() -> Unit { }
///|
fn f01() -> Unit { }
///|
fn f02() -> Unit { }
///|
fn f03() -> Unit { }
///|
fn f04() -> Unit { }
///|
fn f05() -> Unit { }
///|
fn f06() -> Unit { }
///|
fn f07() -> Unit { }
///|
fn f08() -> Unit { }
///|
fn f09() -> Unit { }
///|
fn f10() -> Unit { }
///|
fn f11() -> Unit { }
///|
fn f12() -> Unit { }
///|
fn f13() -> Unit { }
///|
fn f14() -> Unit { }
///|
fn f15() -> Unit { }
///|
fn f16() -> Unit { }
///|
fn f17() -> Unit { }
///|
fn f18() -> Unit { }
///|
fn f19() -> Unit { }
