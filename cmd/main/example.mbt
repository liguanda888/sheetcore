///|
/// `sheetcore example` —— 一张**真实用途**的报价单。
///
/// 为什么需要它：`demo` 用的是 `A1*2` 这样的抽象链，能证明增量重算有效，
/// 但看不出这个内核**实际能拿来干什么**。这里放一张会真的出现在工作里的表：
/// 逐行金额、合计、折扣、含税，改动一行数量会牵动后面几格。
///
/// 刻意只用已实现的函数（`SUM` / `ROUND` / 四则运算 / 区域），
/// 所以这段输出在任何时候都是真的，不是设想。

///|
/// 报价单的初始数据。
fn quotation_entries() -> Array[(String, String)] {
  [
    // 表头
    ("A1", "项目"),
    ("B1", "数量"),
    ("C1", "单价"),
    ("D1", "金额"),
    // 明细行：金额 = 数量 × 单价
    ("A2", "键盘"),
    ("B2", "12"),
    ("C2", "199"),
    ("D2", "=B2*C2"),
    ("A3", "显示器"),
    ("B3", "4"),
    ("C3", "1299"),
    ("D3", "=B3*C3"),
    ("A4", "线材"),
    ("B4", "30"),
    ("C4", "25"),
    ("D4", "=B4*C4"),
    // 汇总：标签放 A 列，数值放 D 列，与上面的金额列对齐
    ("A6", "合计"),
    ("D6", "=SUM(D2:D4)"),
    ("A7", "折扣率"),
    ("D7", "0.1"),
    ("A8", "折扣"),
    ("D8", "=ROUND(D6*D7,2)"),
    ("A9", "应收"),
    ("D9", "=D6-D8"),
    ("A10", "含税"),
    ("D10", "=ROUND(D9*1.13,2)"),
  ]
}

///|
fn run_example() -> Unit {
  let wb = @engine.Workbook::new()
  match wb.set_many(quotation_entries()) {
    Ok(_) => ()
    Err(@formula.ParseError(msg, pos)) => {
      // 内置示例解析失败只可能是代码写错了，照实说出来
      println(
        "internal error: the built-in example does not parse (" +
        msg +
        " @" +
        pos.to_string() +
        ")",
      )
      return
    }
  }
  let first = wb.recalculate()
  println("=== 一张报价单 ===")
  println("")
  println(render_quotation(wb))
  println("")
  println(render_trace(first))
  println("")
  println("=== 把显示器的数量从 4 改成 6 ===")
  match wb.set("B3", "6") {
    Ok(_) => ()
    Err(_) => {
      println("internal error: could not update B3")
      return
    }
  }
  let second = wb.recalculate()
  println("")
  println(render_quotation(wb))
  println("")
  println(render_trace(second))
  println("")
  println(
    "只有显示器那一行、以及它下游的合计/折扣/应收/含税被重算；\n" +
    "键盘与线材那两行没有动 —— 它们和这次改动没有任何依赖关系。",
  )
}

///|
/// 把报价单渲染成人类可读的表格。
///
/// 刻意不用通用的 `render_sheet`：那张表是按格子名排序的，
/// 对整片数据表读起来很别扭。这里按行列排版，因为它要给人看。
///
/// 对齐交给 `@render.render_table` —— 它按**显示列数**补空格，
/// 因此中英混排不会错列（这一点单独成包并测过：第一版按字符数补，表格是歪的）。
fn render_quotation(wb : @engine.Workbook) -> String {
  let rows : Array[Array[String]] = []
  let mut row = 1
  while row <= 10 {
    let cells : Array[String] = []
    let mut col = 0
    while col < 4 {
      let key = @reference.column_name(col) + row.to_string()
      cells.push(wb.display(key))
      col = col + 1
    }
    rows.push(cells)
    row = row + 1
  }
  // 第 5 行是分隔（下标 4）
  @render.render_table(rows, [4])
}
