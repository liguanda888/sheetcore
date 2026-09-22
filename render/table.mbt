///|
/// 终端里的列宽与对齐。
///
/// 核心概念：**显示列数 ≠ 字符数**。
/// 等宽终端下一个汉字占 2 列、一个 ASCII 字符占 1 列，
/// 所以按字符数补空格会让中英混排的表格逐列错开。

///|
/// 一个字符占几个显示列。
///
/// 只区分"宽"与"窄"两档，不追求完整的 Unicode East Asian Width 表 ——
/// 覆盖的是实际会出现在表格里的字符：CJK 汉字、假名、谚文、全角标点。
/// 更全的表（含 emoji、组合字符）需要引入依赖，与"零依赖"冲突，
/// 收益也不成比例。
pub fn char_width(ch : Char) -> Int {
  let c = ch.to_int()
  // 这些区间在等宽终端下都占两列
  if (c >= 0x1100 && c <= 0x115F) || // 谚文字母
    (c >= 0x2E80 && c <= 0x303E) || // CJK 部首、康熙部首、CJK 符号
    (c >= 0x3041 && c <= 0x33FF) || // 平假名、片假名、注音、谚文兼容、CJK 兼容
    (c >= 0x3400 && c <= 0x4DBF) || // CJK 扩展 A
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK 基本区
    (c >= 0xA000 && c <= 0xA4CF) || // 彝文
    (c >= 0xAC00 && c <= 0xD7A3) || // 谚文音节
    (c >= 0xF900 && c <= 0xFAFF) || // CJK 兼容表意文字
    (c >= 0xFE30 && c <= 0xFE4F) || // CJK 兼容形式
    (c >= 0xFF00 && c <= 0xFF60) || // 全角形式
    (c >= 0xFFE0 && c <= 0xFFE6) {
    2
  } else {
    1
  }
}

///|
/// 一段文本占多少显示列。
pub fn display_width(text : StringView) -> Int {
  let mut width = 0
  for ch in text {
    width = width + char_width(ch)
  }
  width
}

///|
/// 右侧补空格到指定**显示列数**。已经够宽就原样返回（不截断）。
pub fn pad_right(text : StringView, width : Int) -> String {
  let buf = StringBuilder::StringBuilder()
  buf.write_string(text.to_owned())
  let mut current = display_width(text)
  while current < width {
    buf.write_char(' ')
    current = current + 1
  }
  buf.to_string()
}

///|
/// 左侧补空格到指定列数（数字右对齐用）。
pub fn pad_left(text : StringView, width : Int) -> String {
  let buf = StringBuilder::StringBuilder()
  let mut current = display_width(text)
  while current < width {
    buf.write_char(' ')
    current = current + 1
  }
  buf.write_string(text.to_owned())
  buf.to_string()
}

///|
/// 把若干行若干列排成对齐的表格。
///
/// - 每列的宽度取该列所有单元格里最宽的
/// - 单元格内容按列宽右补空格
/// - 行尾不留多余空格
/// - `empty_row` 为 `true` 时输出一个空行（用于分组）
pub fn render_table(
  rows : Array[Array[String]],
  empty_rows : Array[Int],
) -> String {
  // 先量每列宽度
  let widths : Array[Int] = []
  for row in rows {
    let mut i = 0
    for cell in row {
      let w = display_width(cell)
      if i >= widths.length() {
        widths.push(w)
      } else if w > widths[i] {
        widths[i] = w
      }
      i = i + 1
    }
  }
  let buf = StringBuilder::StringBuilder()
  let mut row_index = 0
  for row in rows {
    // 分组空行
    for marker in empty_rows {
      if marker == row_index {
        buf.write_string("\n")
      }
    }
    // 找到该行最后一个非空单元格，避免行尾一堆空格
    let mut last = row.length() - 1
    while last >= 0 && row[last] == "" {
      last = last - 1
    }
    let mut i = 0
    for cell in row {
      if i > last {
        break
      }
      let col_width = if i < widths.length() { widths[i] } else { 0 }
      // 列间留两个空格
      buf.write_string(pad_right(cell, col_width + 2))
      i = i + 1
    }
    buf.write_string("\n")
    row_index = row_index + 1
  }
  buf.to_string()
}
