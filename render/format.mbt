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

///|
/// 名词单复数：`1 run` / `3 runs`。
///
/// 为什么需要：`--repeat=1` 很常见（CI 里就是这么跑的），不处理就会打印
/// "minimum of 1 runs"。凡是数字与名词挨着出现的地方都要过这一手。
///
/// 只加 `s`，不做 `-y` → `-ies` 这类英语变形 —— 这里用到的词
/// （run / chain / cell）都是规则名词，为它们写一套词法规则不值得。
pub fn plural(n : Int, singular : String) -> String {
  if n == 1 {
    "1 " + singular
  } else {
    n.to_string() + " " + singular + "s"
  }
}
