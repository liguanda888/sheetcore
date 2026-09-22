///|
/// SheetCore 命令行。
///
/// 这一层**只做 I/O**：把 `@cli.parse` 的结果执行出来，把结果打到 stdout。
/// 参数怎么解释、用法文本长什么样，全在 `cli/` 里（纯逻辑、可离线断言）。
///
/// 为什么这样切：参数解析原来就长在这里，而这是唯一没有测试的包 ——
/// 于是「拼错的子命令被当成单元格内容」「--help 报错而不是给帮助」
/// 这类毛病只能靠手敲才发现。规则搬走之后，它们被 25 条测试钉住了。

///|
fn main {
  let argv = @env.args()
  // argv[0] 是可执行文件名，跳过
  let args : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    args.push(argv[i])
    i = i + 1
  }
  match @cli.parse(args) {
    @cli.Command::Eval(show_trace, entries) => run_eval(entries, show_trace)
    @cli.Command::Demo => run_demo()
    @cli.Command::Example => run_example()
    @cli.Command::Bench(opts) => run_bench(opts)
    @cli.Command::Help(topic) => println(@cli.usage_for(topic))
    @cli.Command::Bad(message, usage) => {
      println("error: " + message)
      println("")
      println(usage)
    }
  }
}

///|
/// 求值一张表并打印。`entries` 已由 `@cli` 切好，这里只负责喂给引擎。
fn run_eval(entries : Array[(String, String)], show_trace : Bool) -> Unit {
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
