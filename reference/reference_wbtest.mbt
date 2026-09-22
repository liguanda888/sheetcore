///|
/// 白盒测试：A1 记法、`$` 绝对标记、跨表引用、区域展开。
///
/// 这一层最容易出错的地方是**身份与回显混为一谈**：
/// `$A$1` 与 `A1` 在依赖图上是同一个格子，但回显时必须保留 `$`。
/// 下面的测试把这两件事分开断言。

// ---------------------------------------------------------------- 列名互转

///|
test "column names follow bijective base-26, not ordinary base-26" {
  // 关键区别：没有"第 0 个字母"。A=1..Z=26, AA=27..
  assert_eq(column_name(0), "A")
  assert_eq(column_name(1), "B")
  assert_eq(column_name(25), "Z")
  // 若按普通 26 进制算，26 会得到 "BA"，这里必须是 "AA"
  assert_eq(column_name(26), "AA")
  assert_eq(column_name(27), "AB")
  assert_eq(column_name(51), "AZ")
  assert_eq(column_name(52), "BA")
  assert_eq(column_name(701), "ZZ")
  assert_eq(column_name(702), "AAA")
}

///|
test "column name and index round-trip across the boundary values" {
  let cols : Array[Int] = [0, 1, 25, 26, 27, 51, 52, 701, 702, 16383]
  for c in cols {
    let name = column_name(c)
    assert_eq(column_index(name), Some(c))
  }
}

///|
test "column_index accepts lowercase and rejects junk" {
  assert_eq(column_index("a"), Some(0))
  assert_eq(column_index("aa"), Some(26))
  assert_eq(column_index(""), None)
  assert_eq(column_index("A1"), None)
  assert_eq(column_index("A B"), None)
  // 超过 Excel 的列上限（XFD = 16383）
  assert_eq(column_index("XFE"), None)
  assert_eq(column_index("ZZZZZZZ"), None)
}

// ---------------------------------------------------------------- 解析引用

///|
test "parses plain, lowercase and absolute cell references" {
  let a1 = match CellRef::parse("A1") {
    Some(r) => r
    None => fail("A1 应该能解析")
  }
  assert_eq(a1.col, 0)
  assert_eq(a1.row, 0)
  assert_false(a1.col_abs)
  assert_false(a1.row_abs)
  assert_true(a1.sheet is None)

  // 小写等价
  assert_eq(CellRef::parse("a1").unwrap().canonical(), "A1")
  assert_eq(CellRef::parse("AB100").unwrap().col, 27)
  assert_eq(CellRef::parse("AB100").unwrap().row, 99)

  // 四种 $ 组合
  let all_abs = CellRef::parse("$A$1").unwrap()
  assert_true(all_abs.col_abs && all_abs.row_abs)
  let col_abs = CellRef::parse("$A1").unwrap()
  assert_true(col_abs.col_abs && !col_abs.row_abs)
  let row_abs = CellRef::parse("A$1").unwrap()
  assert_true(!row_abs.col_abs && row_abs.row_abs)
}

///|
test "rejects malformed cell references" {
  assert_true(CellRef::parse("") is None)
  assert_true(CellRef::parse("A") is None)
  assert_true(CellRef::parse("1") is None)
  // 行列顺序写反
  assert_true(CellRef::parse("1A") is None)
  // 行号从 1 开始，A0 非法
  assert_true(CellRef::parse("A0") is None)
  // 多余字符
  assert_true(CellRef::parse("A1B") is None)
  assert_true(CellRef::parse("A1 2") is None)
  // 只有 $
  assert_true(CellRef::parse("$") is None)
  assert_true(CellRef::parse("$A") is None)
  assert_true(CellRef::parse("$1") is None)
  // 行号超上限
  assert_true(CellRef::parse("A1048577") is None)
}

///|
test "row 1 maps to internal row 0 and back" {
  // 内部 0 基、外部 1 基，这条边界最容易差一位。
  assert_eq(CellRef::parse("A1").unwrap().row, 0)
  assert_eq(cell_ref(0, 0).to_text(), "A1")
  assert_eq(CellRef::parse("A1048576").unwrap().row, 1048575)
}

// ---------------------------------------------------------------- 回显与身份

///|
test "to_text preserves the dollar signs the user wrote" {
  assert_eq(CellRef::parse("A1").unwrap().to_text(), "A1")
  assert_eq(CellRef::parse("$A$1").unwrap().to_text(), "$A$1")
  assert_eq(CellRef::parse("$A1").unwrap().to_text(), "$A1")
  assert_eq(CellRef::parse("A$1").unwrap().to_text(), "A$1")
}

///|
test "canonical treats absolute and relative forms as the same cell" {
  // 这是依赖图正确的前提：$A$1 与 A1 必须是同一个 key。
  assert_eq(CellRef::parse("$A$1").unwrap().canonical(), "A1")
  assert_eq(CellRef::parse("$A1").unwrap().canonical(), "A1")
  assert_eq(CellRef::parse("A$1").unwrap().canonical(), "A1")
  assert_eq(CellRef::parse("a1").unwrap().canonical(), "A1")
  assert_true(
    CellRef::parse("$A$1").unwrap().same_cell(CellRef::parse("A1").unwrap()),
  )
  // 但回显仍然不同 —— 两件事必须分开
  assert_true(
    CellRef::parse("$A$1").unwrap().to_text() !=
    CellRef::parse("A1").unwrap().to_text(),
  )
}

// ---------------------------------------------------------------- 跨表引用

///|
test "parses cross-sheet references" {
  let r = CellRef::parse("Sheet2!A1").unwrap()
  assert_eq(r.sheet, Some("Sheet2"))
  assert_eq(r.col, 0)
  assert_eq(r.row, 0)
  assert_eq(r.to_text(), "Sheet2!A1")
  assert_eq(r.canonical(), "Sheet2!A1")
}

///|
test "cross-sheet references keep the sheet name in the identity" {
  // Sheet2!A1 与 A1 是不同的格子，身份不能混。
  assert_true(
    CellRef::parse("Sheet2!A1").unwrap().canonical() !=
    CellRef::parse("A1").unwrap().canonical(),
  )
}

///|
test "sheet names with spaces are quoted and unquoted correctly" {
  let r = CellRef::parse("'My Sheet'!A1").unwrap()
  assert_eq(r.sheet, Some("My Sheet"))
  // 回显要重新加引号，否则会在 '!' 处解析歧义
  assert_eq(r.to_text(), "'My Sheet'!A1")
  assert_eq(quote_sheet("Plain"), "Plain")
  assert_eq(quote_sheet("My Sheet"), "'My Sheet'")
  assert_eq(quote_sheet(""), "''")
}

///|
test "escaped single quotes inside a sheet name survive a round-trip" {
  // 表名 It's 要写成 'It''s'
  let r = CellRef::parse("'It''s'!B2").unwrap()
  assert_eq(r.sheet, Some("It's"))
  assert_eq(r.to_text(), "'It''s'!B2")
}

// ---------------------------------------------------------------- 区域

///|
test "parses ranges and single-cell ranges" {
  let r = RangeRef::parse("A1:B10").unwrap()
  assert_eq(r.cell_count(), 20)
  assert_eq(r.to_text(), "A1:B10")
  assert_false(r.is_single())

  let single = RangeRef::parse("C3").unwrap()
  assert_true(single.is_single())
  assert_eq(single.cell_count(), 1)
  assert_eq(single.to_text(), "C3:C3")
}

///|
test "range bounds normalise a reversed corner without rewriting it" {
  // 用户写 B10:A1 也合法；边界要归一，但回显保持原样。
  let r = RangeRef::parse("B10:A1").unwrap()
  let (c1, r1, c2, r2) = r.bounds()
  assert_eq((c1, r1, c2, r2), (0, 0, 1, 9))
  assert_eq(r.cell_count(), 20)
  assert_eq(r.to_text(), "B10:A1")
}

///|
test "expands a range in row-major order" {
  let r = RangeRef::parse("A1:B2").unwrap()
  let cells = match r.cells() {
    Some(c) => c
    None => fail("A1:B2 应该能展开")
  }
  assert_eq(cells.length(), 4)
  // 先左到右，再上到下
  assert_eq(cells[0].canonical(), "A1")
  assert_eq(cells[1].canonical(), "B1")
  assert_eq(cells[2].canonical(), "A2")
  assert_eq(cells[3].canonical(), "B2")
}

///|
test "cross-sheet ranges push the sheet name onto every cell" {
  let r = RangeRef::parse("Sheet2!A1:B2").unwrap()
  assert_eq(r.sheet, Some("Sheet2"))
  assert_eq(r.canonical(), "Sheet2!A1:B2")
  let cells = r.cells().unwrap()
  for c in cells {
    assert_eq(c.sheet, Some("Sheet2"))
  }
  assert_eq(cells[0].canonical(), "Sheet2!A1")
}

///|
test "rejects ranges that do not make sense" {
  assert_true(RangeRef::parse("") is None)
  assert_true(RangeRef::parse("A1:") is None)
  assert_true(RangeRef::parse(":B2") is None)
  assert_true(RangeRef::parse("A1:B") is None)
  assert_true(RangeRef::parse("A1:B2:C3") is None)
  // 跨不同表的两端
  assert_true(RangeRef::parse("Sheet1!A1:Sheet2!B2") is None)
}

///|
test "huge ranges are refused rather than silently truncated" {
  // 静默截断会让 SUM(A1:XFD1048576) 给出一个看起来正常但错误的答案。
  let r = RangeRef::parse("A1:XFD1048576").unwrap()
  // 精确值是 16384 × 1048576 = 171 亿，32 位 Int 装不下 ——
  // 早期版本会回绕成 0，导致下面的判断失效、cells() 静默返回空数组。
  assert_eq(r.exact_cell_count(), 17179869184L)
  assert_true(r.cell_count() > max_range_cells)
  assert_true(r.cells() is None)
}

///|
test "cell_count is exact for ranges that fit and saturates beyond the limit" {
  // 装得下时必须是精确值，否则依赖"格子数"的逻辑会错。
  assert_eq(RangeRef::parse("A1:B10").unwrap().cell_count(), 20)
  assert_eq(RangeRef::parse("A1:A1048576").unwrap().cell_count(), 1048576)
  assert_eq(
    RangeRef::parse("A1:B1048576").unwrap().cell_count(),
    max_range_cells + 1,
  )
}

///|
test "range identity ignores dollar signs on both corners" {
  assert_eq(
    RangeRef::parse("$A$1:$B$10").unwrap().canonical(),
    RangeRef::parse("A1:B10").unwrap().canonical(),
  )
}
