///|
/// SheetCore 命令行。
///
/// 用法：
///   sheetcore eval A1=1 A2=2 B1==A1+A2       求值并打印整张表
///   sheetcore eval --trace A1=1 B1==A1+1     同时打印重算轨迹
///   sheetcore demo                           演示增量重算
///   sheetcore --help
///
/// 参数里 `CELL=CONTENT` 只在**第一个** `=` 处切分，所以 `B1==A1+A2`
/// 会正确得到单元格 `B1` 与内容 `=A1+A2`。

///|
fn main {
  let args = @env.args()
  // args[0] 是可执行文件名，跳过
  let rest : Array[String] = []
  let mut i = 1
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  if rest.length() == 0 {
    println(usage())
    return
  }
  match rest[0] {
    "eval" => run_eval(tail(rest))
    "demo" => run_demo()
    "example" => run_example()
    "bench" => run_bench(tail(rest))
    "--help" | "-h" | "help" => println(usage())
    _ =>
      // 没有子命令时，把全部参数当 `CELL=CONTENT` 处理，方便随手用
      run_eval(rest)
  }
}

///|
fn usage() -> String {
  "SheetCore — a spreadsheet calculation core in pure MoonBit\n" +
  "\n" +
  "Usage:\n" +
  "  sheetcore eval A1=1 A2=2 B1==A1+A2     evaluate a sheet and print it\n" +
  "  sheetcore eval --trace A1=1 B1==A1+1   also print the recalculation trace\n" +
  "  sheetcore demo                         demonstrate incremental recalculation\n" +
  "  sheetcore example                      a realistic quotation sheet\n" +
  "  sheetcore bench [--chains=N] [--length=L] [--repeat=R]\n" +
  "                                         incremental vs full recalculation\n" +
  "  sheetcore --help\n" +
  "\n" +
  "Cell content starting with '=' is a formula; anything else is a literal.\n" +
  "Only the first '=' splits cell from content, so B1==A1+A2 works."
}

///|
fn tail(items : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut i = 1
  while i < items.length() {
    out.push(items[i])
    i = i + 1
  }
  out
}

///|
fn run_eval(args : Array[String]) -> Unit {
  let entries : Array[(String, String)] = []
  let mut show_trace = false
  for a in args {
    if a == "--trace" {
      show_trace = true
      continue
    }
    match split_first(a, '=') {
      Some(pair) => entries.push(pair)
      None => {
        println("error: expected CELL=CONTENT but got: " + a)
        return
      }
    }
  }
  if entries.length() == 0 {
    println("error: nothing to evaluate")
    return
  }
  let wb = @engine.Workbook::new()
  match wb.set_many(entries) {
    Ok(_) => ()
    Err(@formula.ParseError(msg, pos)) => {
      println("parse error at token " + pos.to_string() + ": " + msg)
      return
    }
  }
  let trace = wb.recalculate()
  println(render_sheet(wb))
  if show_trace {
    println("")
    println(render_trace(trace))
  }
}

///|
/// 演示：建一张表，改一个格子，展示**只有受影响的格子被重算**。
fn run_demo() -> Unit {
  let entries : Array[(String, String)] = [
    ("A1", "10"),
    ("A2", "20"),
    ("A3", "30"),
    ("B1", "=A1*2"),
    ("B2", "=A2*2"),
    ("B3", "=A3*2"),
    ("C1", "=SUM(B1:B3)"),
  ]
  let wb = @engine.Workbook::new()
  match wb.set_many(entries) {
    Ok(_) => ()
    Err(_) => {
      println("error: internal failure while building the demo sheet")
      return
    }
  }
  let first = wb.recalculate()
  println("=== 1. build the sheet ===")
  println(render_sheet(wb))
  println("")
  println(render_trace(first))
  println("")
  println("=== 2. change A1 from 10 to 100 ===")
  match wb.set("A1", "100") {
    Ok(_) => ()
    Err(_) => {
      println("error: could not update A1")
      return
    }
  }
  let second = wb.recalculate()
  println(render_sheet(wb))
  println("")
  println(render_trace(second))
  println("")
  println(
    "A1 -> B1 -> C1 is the only chain affected. B2 and B3 did not depend on A1,\n" +
    "so they were left alone — that is the whole point of incremental recalculation.",
  )
}

///|
/// 把整张表渲染成 `A1 = 1` 这样的行，按格子名排序。
fn render_sheet(wb : @engine.Workbook) -> String {
  let buf = StringBuilder::StringBuilder()
  let keys = wb.keys()
  for key in keys {
    buf.write_string(key)
    buf.write_string(" = ")
    buf.write_string(wb.display(key))
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// 渲染重算轨迹。
fn render_trace(trace : @engine.Trace) -> String {
  let buf = StringBuilder::StringBuilder()
  buf.write_string("recomputed ")
  buf.write_string(trace.recomputed.length().to_string())
  buf.write_string(" of ")
  buf.write_string(trace.total_cells.to_string())
  buf.write_string(" cells")
  if trace.recomputed.length() > 0 {
    buf.write_string(": ")
    let mut first = true
    for key in trace.recomputed {
      if !first {
        buf.write_string(" -> ")
      }
      buf.write_string(key)
      first = false
    }
  }
  if trace.cycles.length() > 0 {
    buf.write_string("\ncircular reference detected in: ")
    buf.write_string(@graph.join_keys(trace.cycles))
  }
  if trace.error_cells > 0 {
    buf.write_string("\nerror cells: ")
    buf.write_string(trace.error_cells.to_string())
  }
  buf.to_string()
}

///|
/// 在**第一个** `sep` 处切分。返回 `None` 表示没有分隔符。
fn split_first(s : StringView, sep : Char) -> (String, String)? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut i = 0
  while i < chars.length() && chars[i] != sep {
    i = i + 1
  }
  if i >= chars.length() {
    return None
  }
  let head = StringBuilder::StringBuilder()
  let mut k = 0
  while k < i {
    head.write_char(chars[k])
    k = k + 1
  }
  let rest = StringBuilder::StringBuilder()
  let mut j = i + 1
  while j < chars.length() {
    rest.write_char(chars[j])
    j = j + 1
  }
  Some((head.to_string(), rest.to_string()))
}
