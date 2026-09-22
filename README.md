# SheetCore

**一个纯 MoonBit 实现的电子表格计算内核。**
公式解析 → 依赖图 → **增量重算** → 错误传播。

不依赖任何第三方包，不使用 FFI。

---

## 这是什么

电子表格（Excel / Google Sheets）背后有一个**计算内核**，它和界面完全是两件事。
你输入 `=SUM(A1:A10)` 时真正发生的是：

```
公式文本  --词法/语法分析-->  AST  --建依赖图-->  拓扑序重算  -->  值
                                ↑                              │
                                └──── 某个格子变了，只重算受影响的部分
```

SheetCore 做的就是这件事的 **MoonBit 实现**，不含任何 UI。
它面向的场景是：**把表格计算能力嵌进程序里** —— 配置表、规则表、
财务模型、参数化的业务表格，以及需要在代码里安全求值用户公式的地方。

## 特色：可解释的增量重算

这是它区别于"把公式求个值"的地方。

| 能力 | 说明 |
|---|---|
| **增量重算** | 改一个格子，只重算**真正依赖它**的格子，而不是整张表。用基准测试给出"重算了几个格子、耗时多少"，而不是只说"很快" |
| **可解释的重算轨迹** | 每次重算都记录：改了哪个格子 → 影响了哪些格子 → 按什么依赖顺序重算 → 每个格子算了多久 |
| **可复现** | 同一输入必然得到同一结果与同一重算顺序。所有排序都有确定的 tie-break，不依赖哈希或遍历顺序 |
| **错误是值，不是异常** | `#DIV/0!` 像普通值一样在依赖图里传播、能被 `ISERROR` 检测、能被排序。一个格子的错误不会让整张表算不出来 |
| **零依赖、无 FFI** | 纯 MoonBit，可在 native / wasm / js 后端运行 |

## 模块划分

每个包都是**纯逻辑**（除 `cmd/main`），可离线单元测试：

| 包 | 负责 |
|---|---|
| `value/` | 单元格值类型、错误值、**类型强制转换**（电子表格的隐式转换规则） |
| `reference/` | A1 记法：`A1`、`$A$1`、`A1:B10`、`Sheet2!A1` |
| `formula/` | 公式语言：词法分析、语法分析、AST、回显 |
| `graph/` | 依赖图：建图、拓扑排序、**环检测** |
| `engine/` | 增量重算引擎、错误传播、计算轨迹 |
| `functions/` | 函数库（数学/逻辑/文本/查找/统计） |
| `render/` | 终端排版：显示列宽、表格对齐、比值格式 |
| `cli/` | 命令行解析：子命令、选项、用法文本 |
| `cmd/main/` | 命令行入口（**纯 I/O**，不做解析） |

根包 `sheetcore.mbt` 只放版本号与一句话描述，供 `sheetcore --version` 打印。

## 状态

早期开发中，但**已经能跑**。各包的实现与测试情况：

| 包 | 状态 | 测试数 |
|---|---|---|
| `value/` 值类型与强制转换 | ✅ | 22 |
| `reference/` A1 记法与区域 | ✅ | 20 |
| `formula/` 词法、AST、语法分析 | ✅ | 31 |
| `graph/` 依赖图、拓扑排序、环检测 | ✅ | 17 |
| `engine/` 增量重算、错误传播、查找函数集成 | ✅ | 52 |
| `functions/` 函数库（**37 个**） | ✅ | 覆盖在 engine 用例里 |
| `render/` 终端排版（显示列宽、表格对齐、比值格式） | ✅ | 15 |
| `cli/` 命令行解析（子命令、选项、用法文本） | ✅ | 26 |
| `cmd/main/` CLI | ✅ | 手动 + CI 验证 |

```
moon test --target native   →  Total tests: 183, passed: 183, failed: 0
```

函数覆盖：聚合（`SUM`/`PRODUCT`/`AVERAGE`/`MIN`/`MAX`/`MEDIAN`/`COUNT`/
`COUNTA`/`COUNTBLANK`）、数学（`ABS`/`INT`/`SIGN`/`SQRT`/`POWER`/`MOD`/`ROUND`）、
逻辑（`AND`/`OR`/`NOT`/`ISERROR`/`ISBLANK`/`ISNUMBER`/`ISTEXT`/`ISLOGICAL`/`ISNA`）、
查找（`VLOOKUP`/`HLOOKUP`/`MATCH`/`INDEX`）、文本（`LEN`/`UPPER`/`LOWER`/`TRIM`/`CONCAT`）、
以及由引擎惰性处理的 `IF`/`IFERROR`/`IFNA`。

**尚未实现**：本地文件格式的读写（如 xlsx）、日期时间类型、数组公式。

## 试试看

```bash
moon build --target native

# 求值一张表
_build/native/debug/build/cmd/main/main.exe eval A1=10 A2=20 B1==A1+A2
#   A1 = 10
#   A2 = 20
#   B1 = 30

# 顺便看重算轨迹
_build/native/debug/build/cmd/main/main.exe eval --trace A1=1 B1==A1+1 C1==B1*2
#   recomputed 3 of 3 cells: A1 -> B1 -> C1

# 演示增量重算（录制演示视频用的就是它）
_build/native/debug/build/cmd/main/main.exe demo

# 一张真实用途的报价单：改动一行，看它牵动哪些格子
_build/native/debug/build/cmd/main/main.exe example

# 量一下增量到底省了多少
_build/native/debug/build/cmd/main/main.exe bench

# 有什么命令、某个选项是什么意思
_build/native/debug/build/cmd/main/main.exe help
_build/native/debug/build/cmd/main/main.exe help bench
_build/native/debug/build/cmd/main/main.exe --version
```

`example` 的输出（一张会真的出现在工作里的表）：

```
项目    数量  单价  金额
键盘    12    199   2388
显示器  4     1299  5196
线材    30    25    750

合计                8334
折扣率              0.1
折扣                833.4
应收                7500.6
含税                8475.68

=== 把显示器的数量从 4 改成 6 ===
...
合计                10932
含税                11117.84

recomputed 6 of 26 cells: B3 -> D3 -> D6 -> D8 -> D9 -> D10
```

只有显示器那一行和它下游的五格被重算；键盘与线材那两行没动。

`bench` 的输出（本机实测）：

```
building 10 independent chains of 1000 cells (10000 cells)

full recalculation
  10000 cells in 50 ms
incremental recalculation (one head changed)
  1000 cells in 3 ms

cells recomputed: 10.0x fewer
wall clock:       16.6x faster
```

规模再大一点（4 万格）：全量 276 ms、增量 13 ms，**格子少 20 倍、快 21.2 倍**。

> **格子数是精确的，耗时是单机测的。** 程序会取多次重复中的**最小值** ——
> 调度抖动只会让某一次变慢，不会让某一次变快，所以最小值最接近真实开销。
> 两次运行的数字会略有出入，这是正常的；格子数则每次都一样。
> 两者都打印出来，是为了不让读者误以为耗时也是可复现的。
>
> 规模太小时（全量与增量都在 1 毫秒上下），程序会直接说
> **"not measurable at this size"**，而不是报一个 `1.0x` 让人误以为没有提升。

`demo` 的输出：

```
=== 2. change A1 from 10 to 100 ===
A1 = 100   A2 = 20   A3 = 30
B1 = 200   B2 = 40   B3 = 60
C1 = 300

recomputed 3 of 7 cells: A1 -> B1 -> C1
```

七个格子里只重算了三个 —— `B2`、`B3` 不依赖 `A1`，所以完全没动。

> **在 Windows 的 PowerShell 里传含双引号的公式会被 shell 吃掉引号**
> （`'B1==IFERROR(1/0,"n/a")'` 到不了程序手里）。这是 PowerShell 向原生程序
> 传参的老问题，不是程序的行为 —— 命令行本身只做原样透传，字符串字面量
> 由单元测试覆盖。需要测这类公式时请写进脚本文件再调用。

## 已知限制

命令行有两处和常见 CLI 不一样，**都是实测出来的**，写在这里而不是等人踩到：

| 限制 | 实测 | 为什么 |
|---|---|---|
| **出错时退出码仍是 0** | `sheetcore nosuchcmd` 打印 `error: unknown command: ...`，退出码 0 | MoonBit core 没有 `exit`。要置非零退出码只能直接调 libc（或 js 的 `process.exit`），也就是逐后端写 FFI —— core 自带的 `argparse` 正是这么做的，而且它**只**实现了 exit 0，错误一律 `raise` 出去。本项目把"零依赖、无 FFI、三后端可跑"当成核心取舍，不为退出码破这个例 |
| **错误信息打在 stdout** | `stderr` 长度为 0，`error: ...` 在 stdout | 同上：core 只有 `println`，没有 `eprintln` |

后果很具体：`sheetcore eval ... && 下一步` **不会**因为参数写错而中断。
需要自动化判定的地方，请检查输出里的 `error:` 前缀，而不是退出码 ——
CI 里那一步 `CLI error handling` 就是这么写的。

这个限制有代价，也有边界：它只影响命令行这一层。**内核本身不吞错误** ——
公式错误是 `#DIV/0!` 这样的值，会随依赖图传播、能被 `ISERROR` 检测；
`@cli.parse` 也把"用户说错了什么"当作返回值交给调用方，而不是丢弃。

## 构建

```bash
moon check
moon test --target native
```

## 与 Excel 的已知差异

刻意**不**追求 100% 兼容 —— 逐条列出差异，比声称"兼容 Excel"更有用：

| 项 | Excel | SheetCore | 为什么 |
|---|---|---|---|
| 文本转数字 | `"12abc"` → 12 | `#VALUE!` | Excel 的宽松规则难以预测、也难以测试；只接受纯十进制表示 |
| 千分位 | `"1,000"` → 1000 | `#VALUE!` | 同上；区域设置相关的解析不放进内核 |
| 日期 | 数字 + 格式 | 尚未支持 | 日期是显示层概念，内核先只做数值与文本 |

## 文档

- [设计说明](docs/architecture.md) —— **为什么这样设计**：六个关键决定、
  刻意与 Excel 不同的地方、以及一份缺陷记录（逐条写明后果与"为什么难发现"）

## 许可证

[Apache-2.0](LICENSE) © 2026 李冠达 (liguanda888)