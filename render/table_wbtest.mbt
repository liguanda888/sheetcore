///|
/// 白盒测试：显示列宽与表格对齐。
///
/// 这一层存在的理由就是它出过错：第一版按"字符数"补空格，
/// 中英混排的表格逐列错开。下面第一条测试就是钉住那个 bug。

///|
test "a CJK character occupies two display columns" {
  // 这就是当初算错的地方：字符数是 1，显示列数是 2。
  assert_eq(display_width("项"), 2)
  assert_eq(display_width("项目"), 4)
  assert_eq(display_width("ab"), 2)
  // 中英混排
  assert_eq(display_width("键盘12"), 6)
  assert_eq(display_width(""), 0)
}

///|
test "char_width covers the ranges that actually appear in tables" {
  assert_eq(char_width('a'), 1)
  assert_eq(char_width('1'), 1)
  assert_eq(char_width(' '), 1)
  assert_eq(char_width('中'), 2)
  assert_eq(char_width('あ'), 2) // 平假名
  assert_eq(char_width('한'), 2) // 谚文
  // 全角逗号
  assert_eq(char_width('，'), 2)
}

///|
test "padding counts columns, so CJK and ASCII line up" {
  // "项目" 占 4 列，补到 12 列要加 8 个空格；
  // "键盘" 同理。"ab" 占 2 列，要加 10 个。
  assert_eq(pad_right("项目", 12), "项目" + "        ")
  assert_eq(pad_right("ab", 12), "ab" + "          ")
  // 两者补完的**显示宽度**必须相等 —— 这才是对齐的判据
  assert_eq(display_width(pad_right("项目", 12)), 12)
  assert_eq(display_width(pad_right("ab", 12)), 12)
}

///|
test "padding never truncates" {
  assert_eq(pad_right("abcdef", 3), "abcdef")
  assert_eq(pad_right("中文内容", 2), "中文内容")
  assert_eq(pad_left("abcdef", 3), "abcdef")
}

///|
test "pad_left puts the spaces in front, for right-aligned numbers" {
  assert_eq(pad_left("42", 6), "    42")
  assert_eq(display_width(pad_left("42", 6)), 6)
}

///|
test "render_table aligns columns by display width" {
  let rows : Array[Array[String]] = [
    ["项目", "数量", "金额"],
    ["键盘", "12", "2388"],
    ["显示器", "4", "5196"],
  ]
  let table = render_table(rows, [])
  let lines : Array[String] = []
  for line in table.split("\n") {
    lines.push(line.to_owned())
  }
  // 三行都非空（末尾换行会产生一个空串）
  assert_eq(lines[0], "项目    数量  金额  ")
  // 关键：每行的显示宽度一致，列才对得齐
  assert_eq(display_width(lines[0]), display_width(lines[1]))
  assert_eq(display_width(lines[1]), display_width(lines[2]))
}

///|
test "render_table does not pad the trailing empty cells" {
  let rows : Array[Array[String]] = [["A", "B", "C", "D"], ["x", "", "", ""]]
  let table = render_table(rows, [])
  let lines : Array[String] = []
  for line in table.split("\n") {
    lines.push(line.to_owned())
  }
  // 第二行只有一格有内容：列宽 1 + 列间 2 个空格 = 3 列，行尾不再补
  assert_eq(lines[1], "x  ")
}

///|
test "render_table inserts blank lines at the requested row indices" {
  let rows : Array[Array[String]] = [["a"], ["b"], ["c"]]
  let table = render_table(rows, [1])
  let lines : Array[String] = []
  for line in table.split("\n") {
    lines.push(line.to_owned())
  }
  // 第 1 行之前插一个空行；列宽 1 + 间隔 2 = 3
  assert_eq(lines[0], "a  ")
  assert_eq(lines[1], "")
  assert_eq(lines[2], "b  ")
}

///|
test "an empty table renders as an empty string" {
  assert_eq(render_table([], []), "")
}
