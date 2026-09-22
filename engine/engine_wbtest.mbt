///|
/// 白盒测试：增量重算引擎。
///
/// 最重要的一组断言是 **"这次到底重算了哪些格子"** ——
/// 增量重算是本项目的核心承诺，不能只测"结果对不对"，
/// 还要测"有没有多算"。多算会静默地让性能退化，测不出来。

///|
/// 建表、写入、重算一次。
fn make(entries : Array[(String, String)]) -> Workbook {
  let w = Workbook::new()
  match w.set_many(entries) {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  w
}

///|
/// 取某个格子的值。
fn get(w : Workbook, cell : String) -> @value.Value {
  match @reference.CellRef::parse(cell) {
    Some(r) => w.value_of(r.canonical())
    None => abort("不是合法地址：" + cell)
  }
}

///|
/// 取某个格子的显示文本（断言错误字面量时更直观）。
fn show(w : Workbook, cell : String) -> String {
  get(w, cell).display()
}

// ---------------------------------------------------------------- 基础求值

///|
test "stores and reads literals" {
  let w = make([("A1", "42"), ("A2", "hello"), ("A3", "TRUE")])
  assert_eq(get(w, "A1"), @value.Number(42.0))
  assert_eq(get(w, "A2"), @value.Text("hello"))
  assert_eq(get(w, "A3"), @value.Bool(true))
  // 从未写入的格子是空值，不是错误
  assert_eq(get(w, "Z99"), @value.Blank)
}

///|
test "evaluates arithmetic with spreadsheet precedence" {
  let w = make([
    ("A1", "=1+2*3"),
    ("A2", "=(1+2)*3"),
    ("A3", "=-2^2"),
    ("A4", "=50%"),
  ])
  assert_eq(get(w, "A1"), @value.Number(7.0))
  assert_eq(get(w, "A2"), @value.Number(9.0))
  // 电子表格语义：(-2)^2 = 4
  assert_eq(get(w, "A3"), @value.Number(4.0))
  assert_eq(get(w, "A4"), @value.Number(0.5))
}

///|
test "follows references between cells" {
  let w = make([("A1", "2"), ("A2", "3"), ("B1", "=A1+A2"), ("C1", "=B1*2")])
  assert_eq(get(w, "B1"), @value.Number(5.0))
  assert_eq(get(w, "C1"), @value.Number(10.0))
}

///|
test "absolute markers do not create separate cells" {
  let w = make([("A1", "5"), ("B1", "=$A$1+1"), ("B2", "=A1+2")])
  assert_eq(get(w, "B1"), @value.Number(6.0))
  assert_eq(get(w, "B2"), @value.Number(7.0))
}

///|
test "concatenation and comparison" {
  let w = make([
    ("A1", "1"),
    ("A2", "2"),
    ("B1", "=A1&A2"),
    ("B2", "=A1<A2"),
    ("B3", "=A1=A2"),
    ("B4", "=\"a\"&\"b\""),
  ])
  assert_eq(get(w, "B1"), @value.Text("12"))
  assert_eq(get(w, "B2"), @value.Bool(true))
  assert_eq(get(w, "B3"), @value.Bool(false))
  assert_eq(get(w, "B4"), @value.Text("ab"))
}

// ---------------------------------------------------------------- 错误传播

///|
test "division by zero is a value, not a crash" {
  let w = make([("A1", "=1/0")])
  assert_eq(get(w, "A1"), @value.Error(@value.DivByZero))
  assert_eq(show(w, "A1"), "#DIV/0!")
}

///|
test "errors propagate through dependents instead of being rewritten" {
  let w = make([("A1", "=1/0"), ("B1", "=A1+1"), ("C1", "=B1*2")])
  // #DIV/0! 经过 +1 仍然是 #DIV/0!，不能被改写成 #VALUE!
  assert_eq(get(w, "B1"), @value.Error(@value.DivByZero))
  assert_eq(get(w, "C1"), @value.Error(@value.DivByZero))
}

///|
test "one bad cell does not stop the rest of the sheet" {
  // 这是"错误是值"最重要的收益：整张表照常算得出来。
  let w = make([("A1", "=1/0"), ("A2", "10"), ("A3", "20"), ("B2", "=A2+A3")])
  assert_eq(get(w, "B2"), @value.Number(30.0))
  assert_eq(get(w, "A1"), @value.Error(@value.DivByZero))
}

///|
test "ISERROR and IFERROR can inspect errors without propagating" {
  let w = make([
    ("A1", "=1/0"),
    ("B1", "=ISERROR(A1)"),
    ("C1", "=IFERROR(A1,\"fallback\")"),
    ("D1", "=IFERROR(1+1,\"fallback\")"),
  ])
  assert_eq(get(w, "B1"), @value.Bool(true))
  assert_eq(get(w, "C1"), @value.Text("fallback"))
  assert_eq(get(w, "D1"), @value.Number(2.0))
}

// ---------------------------------------------------------------- 环

///|
test "self reference becomes #CYCLE! instead of hanging" {
  let w = make([("A1", "=A1+1")])
  assert_eq(get(w, "A1"), @value.Error(@value.Cycle))
  assert_eq(show(w, "A1"), "#CYCLE!")
}

///|
test "mutual reference marks every cell in the cycle" {
  let w = make([("A1", "=B1"), ("B1", "=A1")])
  assert_eq(get(w, "A1"), @value.Error(@value.Cycle))
  assert_eq(get(w, "B1"), @value.Error(@value.Cycle))
}

///|
test "a cycle does not prevent unrelated cells from computing" {
  let w = make([("A1", "=B1"), ("B1", "=A1"), ("D1", "5"), ("E1", "=D1*2")])
  assert_eq(get(w, "A1"), @value.Error(@value.Cycle))
  assert_eq(get(w, "E1"), @value.Number(10.0))
}

// ---------------------------------------------------------------- 增量重算

///|
test "recalculation only touches cells that actually depend on the change" {
  let w = make([
    ("A1", "1"),
    ("A2", "2"),
    ("B1", "=A1+1"),
    ("B2", "=A2+1"),
    ("C1", "=B1+B2"),
  ])
  // 改 A1：只有 A1 → B1 → C1 这条链受影响，A2/B2 无关
  match w.set("A1", "10") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let trace = w.recalculate()
  assert_eq(trace.recomputed, ["A1", "B1", "C1"])
  assert_eq(trace.total_cells, 5)
  assert_eq(get(w, "C1"), @value.Number(14.0))
  // A2/B2 的值不变，也没有被重算
  assert_eq(get(w, "B2"), @value.Number(3.0))
}

///|
test "the trace order is topological, so every precedent is already computed" {
  let w = make([("A1", "1"), ("B1", "=A1+1"), ("C1", "=B1+1")])
  match w.set("A1", "5") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let trace = w.recalculate()
  assert_eq(trace.recomputed, ["A1", "B1", "C1"])
  assert_eq(get(w, "C1"), @value.Number(7.0))
}

///|
test "recalculation with nothing dirty does no work at all" {
  let w = make([("A1", "1"), ("B1", "=A1+1")])
  let trace = w.recalculate()
  assert_eq(trace.recomputed, [])
  assert_eq(trace.cycles, [])
}

///|
test "changing a formula into a literal cuts its dependency edges" {
  // 关键回归：把 =A1+1 改成 42 之后，A1 的变化不该再触发本格重算。
  // 若不移除旧边，重算集合会越滚越大 —— 增量就名存实亡了。
  let w = make([("A1", "1"), ("B1", "=A1+1")])
  match w.set("B1", "42") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let t1 = w.recalculate()
  assert_eq(t1.recomputed, ["B1"])
  match w.set("A1", "99") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let t2 = w.recalculate()
  // 只有 A1 自己，B1 已被切断
  assert_eq(t2.recomputed, ["A1"])
  assert_eq(get(w, "B1"), @value.Number(42.0))
}

///|
test "changing which cell a formula points at moves the edge" {
  let w = make([("A1", "1"), ("C1", "100"), ("B1", "=A1+1")])
  match w.set("B1", "=C1+1") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let _ = w.recalculate()
  assert_eq(get(w, "B1"), @value.Number(101.0))
  // 改 A1 不再影响 B1
  match w.set("A1", "7") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let trace = w.recalculate()
  assert_eq(trace.recomputed, ["A1"])
  assert_eq(get(w, "B1"), @value.Number(101.0))
}

///|
test "the same operations always produce the same trace" {
  // 可复现性：轨迹必须确定，否则"可解释"就无从谈起。
  let build = fn() -> Array[String] {
    let w = make([
      ("A1", "1"),
      ("B1", "=A1+1"),
      ("C1", "=B1+1"),
      ("D1", "=A1+2"),
    ])
    match w.set("A1", "3") {
      Ok(_) => ()
      Err(_) => abort("写入失败")
    }
    w.recalculate().recomputed
  }
  assert_eq(build(), build())
}

///|
test "a diamond recomputes each cell exactly once" {
  //   A1
  //  /  \
  // B1   C1
  //  \  /
  //   D1
  // D1 有两条路径依赖 A1，但只能被重算一次。
  let w = make([("A1", "1"), ("B1", "=A1"), ("C1", "=A1"), ("D1", "=B1+C1")])
  match w.set("A1", "10") {
    Ok(_) => ()
    Err(_) => abort("写入失败")
  }
  let trace = w.recalculate()
  assert_eq(trace.recomputed, ["A1", "B1", "C1", "D1"])
  assert_eq(get(w, "D1"), @value.Number(20.0))
}

// ---------------------------------------------------------------- 函数与惰性

///|
test "aggregates over a range ignore blanks and text" {
  let w = make([
    ("A1", "1"),
    ("A2", "two"),
    ("A3", "3"),
    ("B1", "=SUM(A1:A3)"),
    ("B2", "=COUNT(A1:A3)"),
    ("B3", "=COUNTA(A1:A3)"),
    ("B4", "=COUNTBLANK(A4:A6)"),
  ])
  // 区域里的文本被忽略（不是报错）
  assert_eq(get(w, "B1"), @value.Number(4.0))
  // COUNT 只数数字
  assert_eq(get(w, "B2"), @value.Number(2.0))
  // COUNTA 数非空
  assert_eq(get(w, "B3"), @value.Number(3.0))
  assert_eq(get(w, "B4"), @value.Number(3.0))
}

///|
test "a text argument to SUM is a type error, unlike text inside a range" {
  // 这条差异是电子表格的真实规则，也是 Arg 分成 Scalar / List 的理由
  let w = make([("A1", "abc"), ("B1", "=SUM(A1)"), ("B2", "=SUM(\"abc\")")])
  assert_eq(get(w, "B1"), @value.Number(0.0))
  assert_eq(get(w, "B2"), @value.Error(@value.ValueType))
}

///|
test "MIN, MAX, AVERAGE and MEDIAN" {
  let w = make([
    ("A1", "3"),
    ("A2", "1"),
    ("A3", "2"),
    ("B1", "=MIN(A1:A3)"),
    ("B2", "=MAX(A1:A3)"),
    ("B3", "=AVERAGE(A1:A3)"),
    ("B4", "=MEDIAN(A1:A3)"),
  ])
  assert_eq(get(w, "B1"), @value.Number(1.0))
  assert_eq(get(w, "B2"), @value.Number(3.0))
  assert_eq(get(w, "B3"), @value.Number(2.0))
  assert_eq(get(w, "B4"), @value.Number(2.0))
}

///|
test "empty aggregates are defined for SUM and PRODUCT only" {
  let w = make([
    ("B1", "=SUM(A1:A3)"),
    ("B2", "=PRODUCT(A1:A3)"),
    ("B3", "=AVERAGE(A1:A3)"),
  ])
  assert_eq(get(w, "B1"), @value.Number(0.0))
  assert_eq(get(w, "B2"), @value.Number(1.0))
  // 没有数字时平均值无定义
  assert_eq(get(w, "B3"), @value.Error(@value.DivByZero))
}

///|
test "IF is lazy, so the untaken branch is never computed" {
  // 这条最要紧：不惰性求值的话，IF(A1=0,0,1/A1) 在 A1=0 时会凭空产生 #DIV/0!
  let w = make([("A1", "0"), ("B1", "=IF(A1=0,0,1/A1)")])
  assert_eq(get(w, "B1"), @value.Number(0.0))
  let w2 = make([("A1", "4"), ("B1", "=IF(A1=0,0,1/A1)")])
  assert_eq(get(w2, "B1"), @value.Number(0.25))
}

///|
test "IF with a missing else branch yields blank" {
  let w = make([("A1", "TRUE"), ("B1", "=IF(A1,5)"), ("B2", "=IF(FALSE,5)")])
  assert_eq(get(w, "B1"), @value.Number(5.0))
  // 没写 else 分支就是 Missing，求值成空值
  assert_eq(get(w, "B2"), @value.Blank)
}

///|
test "logical and text functions" {
  let w = make([
    ("A1", "TRUE"),
    ("B1", "=NOT(A1)"),
    ("B2", "=AND(TRUE,TRUE)"),
    ("B3", "=OR(FALSE,TRUE)"),
    ("B4", "=LEN(\"hello\")"),
    ("B5", "=UPPER(\"abc\")"),
    ("B6", "=TRIM(\"  a   b  \")"),
    ("B7", "=CONCAT(\"a\",1)"),
    ("B8", "=ABS(-5)"),
    ("B9", "=ROUND(3.14159,2)"),
    ("B10", "=MOD(7,3)"),
    ("B11", "=SQRT(16)"),
  ])
  assert_eq(get(w, "B1"), @value.Bool(false))
  assert_eq(get(w, "B2"), @value.Bool(true))
  assert_eq(get(w, "B3"), @value.Bool(true))
  assert_eq(get(w, "B4"), @value.Number(5.0))
  assert_eq(get(w, "B5"), @value.Text("ABC"))
  assert_eq(get(w, "B6"), @value.Text("a b"))
  assert_eq(get(w, "B7"), @value.Text("a1"))
  assert_eq(get(w, "B8"), @value.Number(5.0))
  assert_eq(get(w, "B9"), @value.Number(3.14))
  assert_eq(get(w, "B10"), @value.Number(1.0))
  assert_eq(get(w, "B11"), @value.Number(4.0))
}

///|
test "an unknown function is #NAME?" {
  let w = make([("B1", "=NOPE(1)")])
  assert_eq(get(w, "B1"), @value.Error(@value.Name))
}

///|
test "a range used where a single value is expected is a type error" {
  let w = make([("A1", "1"), ("A2", "2"), ("B1", "=A1:A2+1")])
  assert_eq(get(w, "B1"), @value.Error(@value.ValueType))
}

// ---------------------------------------------------------------- 入口辅助

///|
test "the evaluate helper returns both the sheet and the trace" {
  match evaluate([("A1", "1"), ("B1", "=A1+1")]) {
    Ok(pair) => {
      let (w, trace) = pair
      assert_eq(get(w, "B1"), @value.Number(2.0))
      assert_eq(trace.recomputed, ["A1", "B1"])
      assert_eq(trace.error_cells, 0)
    }
    Err(_) => abort("写入失败")
  }
}

///|
test "evaluate_cell reads a single value" {
  match evaluate_cell([("A1", "2"), ("A2", "3"), ("B1", "=A1*A2")], "B1") {
    Ok(v) => assert_eq(v, @value.Number(6.0))
    Err(_) => abort("写入失败")
  }
}

///|
test "a parse error is reported instead of writing a half-broken cell" {
  let w = Workbook::new()
  assert_true(w.set("A1", "=1+") is Err(_))
  // 解析失败不应留下任何痕迹
  assert_eq(w.keys(), [])
}
