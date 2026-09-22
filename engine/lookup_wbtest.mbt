///|
/// 白盒测试：查找函数 `VLOOKUP` / `HLOOKUP` / `MATCH` / `INDEX`。
///
/// 这些是**二维**函数，走的是与聚合函数不同的路径 ——
/// 它们依赖区域展开时带上的行列数。所以测试刻意通过引擎（写公式）
/// 而不是直接构造 `Arg`：那样才能验证"形状有没有被正确传下来"。

///|
/// 一张纵向查找表（A1:C4）加一张横向查找表（A6:C7）。
///
/// ```
///      A        B        C
/// 1    1        one      10
/// 2    2        two      20
/// 3    3        three    30
/// 4    4        four     40
/// 6    1        2        3
/// 7    one      two      three
/// ```
fn lookup_sheet() -> Workbook {
  make([
    ("A1", "1"),
    ("B1", "one"),
    ("C1", "10"),
    ("A2", "2"),
    ("B2", "two"),
    ("C2", "20"),
    ("A3", "3"),
    ("B3", "three"),
    ("C3", "30"),
    ("A4", "4"),
    ("B4", "four"),
    ("C4", "40"),
    ("A6", "1"),
    ("B6", "2"),
    ("C6", "3"),
    ("A7", "one"),
    ("B7", "two"),
    ("C7", "three"),
  ])
}

// ---------------------------------------------------------------- VLOOKUP

///|
test "VLOOKUP returns the value in the requested column of the matching row" {
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(3,A1:C4,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  match w.set("E2", "=VLOOKUP(2,A1:C4,3,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("three"))
  assert_eq(get(w, "E2"), @value.Number(20.0))
}

///|
test "VLOOKUP column index is one-based, and 0 or negative is a type error" {
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(1,A1:C4,1,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  match w.set("E2", "=VLOOKUP(1,A1:C4,0,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  // 第 1 列是 1，不是 0 —— 取回的是键本身
  assert_eq(get(w, "E1"), @value.Number(1.0))
  assert_eq(get(w, "E2"), @value.Error(@value.ValueType))
}

///|
test "VLOOKUP reports #REF! when the column is outside the table" {
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(1,A1:C4,9,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Error(@value.Ref))
}

///|
test "VLOOKUP reports #N/A when nothing matches exactly" {
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(99,A1:C4,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  // 查不到用 #N/A（"这里没有"），而不是 #VALUE!（"你用错了"）
  assert_eq(get(w, "E1"), @value.Error(@value.NotAvailable))
}

///|
test "VLOOKUP defaults to approximate matching, as spreadsheets do" {
  let w = lookup_sheet()
  // 省略第 4 个参数 = TRUE = 近似：取最大的不超过待查值的行
  match w.set("E1", "=VLOOKUP(3.5,A1:C4,2)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("three"))
}

///|
test "an exact VLOOKUP for a value between rows does not match" {
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(3.5,A1:C4,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Error(@value.NotAvailable))
}

///|
test "a literal is not a table, so VLOOKUP rejects it" {
  let w = make([("A1", "1")])
  match w.set("B1", "=VLOOKUP(1,2,1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  // 若把字面量当成 1×1 的表，这里会"成功"返回 2 —— 那是在掩盖写法错误
  assert_eq(get(w, "B1"), @value.Error(@value.ValueType))
}

// ---------------------------------------------------------------- HLOOKUP

///|
test "HLOOKUP searches the first row and indexes by row" {
  let w = lookup_sheet()
  match w.set("E1", "=HLOOKUP(2,A6:C7,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  match w.set("E2", "=HLOOKUP(3,A6:C7,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("two"))
  assert_eq(get(w, "E2"), @value.Text("three"))
}

///|
test "HLOOKUP reports #REF! when the row is outside the table" {
  let w = lookup_sheet()
  match w.set("E1", "=HLOOKUP(2,A6:C7,9,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Error(@value.Ref))
}

// ---------------------------------------------------------------- MATCH

///|
test "MATCH returns a one-based position" {
  let w = lookup_sheet()
  match w.set("E1", "=MATCH(3,A1:A4,0)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  // A3 是第三个 —— 位置是 3，不是 2
  assert_eq(get(w, "E1"), @value.Number(3.0))
}

///|
test "MATCH with type 1 finds the largest value not exceeding the needle" {
  let w = lookup_sheet()
  match w.set("E1", "=MATCH(3.5,A1:A4,1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Number(3.0))
}

///|
test "MATCH with type -1 finds the smallest value not below the needle" {
  let w = lookup_sheet()
  match w.set("E1", "=MATCH(2.5,A1:A4,-1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  // 升序数据里第一个 >= 2.5 的是 3，位置 3
  assert_eq(get(w, "E1"), @value.Number(3.0))
}

///|
test "MATCH reports #N/A when nothing matches" {
  let w = lookup_sheet()
  match w.set("E1", "=MATCH(99,A1:A4,0)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Error(@value.NotAvailable))
}

///|
test "MATCH defaults to approximate when the third argument is omitted" {
  let w = lookup_sheet()
  match w.set("E1", "=MATCH(3.5,A1:A4)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Number(3.0))
}

// ---------------------------------------------------------------- INDEX

///|
test "INDEX takes one-based row and column numbers" {
  let w = lookup_sheet()
  match w.set("E1", "=INDEX(A1:C4,2,2)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  match w.set("E2", "=INDEX(A1:C4,1,1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("two"))
  assert_eq(get(w, "E2"), @value.Number(1.0))
}

///|
test "INDEX on a single row or column takes the index on that axis" {
  let w = lookup_sheet()
  // A1:C1 是单行 → 一个下标当列号
  match w.set("E1", "=INDEX(A6:C6,2)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  // A1:A4 是单列 → 一个下标当行号
  match w.set("E2", "=INDEX(A1:A4,3)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Number(2.0))
  assert_eq(get(w, "E2"), @value.Number(3.0))
}

///|
test "INDEX reports #REF! outside the range" {
  let w = lookup_sheet()
  match w.set("E1", "=INDEX(A1:C4,9,1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  match w.set("E2", "=INDEX(A1:C4,0,1)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Error(@value.Ref))
  // 下标从 1 开始，0 也不合法
  assert_eq(get(w, "E2"), @value.Error(@value.Ref))
}

// ---------------------------------------------------------------- 组合

///|
test "INDEX and MATCH compose into a lookup that does not need sorted keys" {
  // 这是这对函数的经典用法：MATCH 找位置，INDEX 取值 ——
  // 比 VLOOKUP 灵活（列可以在键的左边）且不要求数据有序。
  let w = lookup_sheet()
  match w.set("E1", "=INDEX(B1:B4,MATCH(4,A1:A4,0))") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("four"))
}

///|
test "a lookup that depends on a changed cell is recalculated" {
  // 查找函数也必须参与依赖图 —— 区域里的格子变了，结果就要跟着变。
  let w = lookup_sheet()
  match w.set("E1", "=VLOOKUP(3,A1:C4,2,FALSE)") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "E1"), @value.Text("three"))
  match w.set("B3", "THREE") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let trace = w.recalculate()
  assert_true(@graph.contains(trace.recomputed, "E1"))
  assert_eq(get(w, "E1"), @value.Text("THREE"))
}
