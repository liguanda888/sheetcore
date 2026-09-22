///|
/// SheetCore 模块根包。
///
/// 目标：一个**纯 MoonBit、无 FFI、零第三方依赖**的电子表格计算内核。
/// 它不做界面，只负责"表格怎么算"：
///
/// `公式文本` → 词法/语法分析 → AST → 依赖图 → 增量重算 → 值
///
/// 子包（纯逻辑的在前）：
/// - `value/`     单元格值、错误值、类型强制转换（纯）
/// - `reference/` A1 记法与区域（纯）
/// - `formula/`   公式语言：词法、语法、AST（纯）
/// - `graph/`     依赖图：建图、拓扑排序、环检测（纯）
/// - `engine/`    增量重算引擎与错误传播（纯）
/// - `functions/` 函数库（纯）
/// - `render/`    终端排版：显示列宽、表格对齐、比值格式（纯）
/// - `cli/`       命令行解析：子命令、选项、用法文本（纯）
/// - `cmd/main/`  只做 I/O：执行解析结果、排版输出（I/O）
///
/// 这个文件以前**不参与编译**（根目录没有 `moon.pkg`），所以上面这份清单
/// 曾经静静漏掉两个子包而无人察觉。补上 `moon.pkg` 之后它才真的被检查。

///|
/// 项目版本号，与 `moon.mod` 保持一致。
pub let version : String = "0.1.0"

///|
/// 一句话描述，供 `sheetcore --version` 打印。
pub fn describe() -> String {
  "SheetCore v" +
  version +
  " — a spreadsheet calculation core in pure MoonBit"
}
