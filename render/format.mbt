///|
/// 数值的显示格式（纯逻辑，可测试）。
///
/// 为什么放在 `render/`：这是**把值排成人类可读文本**的事，和列宽、对齐同类。
/// 它原来长在 `cmd/main` 里 —— 又是那个没有测试的包。

///|
/// 渲染「一个是另一个的几倍」，保留一位小数。
///
/// 用途是基准测试里的 `10.0x fewer`。取整到一位小数，是为了不打印出
/// `16.642857142857142x` 这种长尾巴 —— 尾数没有信息量，只让人以为很精确。
///
/// `actual <= 0` 时返回 `"n/a"`：除法没有意义，返回 0 或无穷都会误导。
pub fn ratio_text(baseline : Int, actual : Int) -> String {
  if actual <= 0 {
    return "n/a"
  }
  let tenths = baseline * 10 / actual
  let whole = tenths / 10
  let frac = tenths % 10
  whole.to_string() + "." + frac.to_string() + "x"
}
