///|
/// 性能基准：**增量重算 vs 全量重算**。
///
/// 为什么需要它：README 里承诺了"用基准测试给出重算了几个格子、耗时多少"，
/// 而不是只说"很快"。只有格子数是硬指标，耗时受机器与调度影响 ——
/// 所以两者都给，并说清各自的性质。
///
/// 场景构造：`M` 条**互不相干**的链，每条长 `L`。
/// 于是总格子数是 `M×L`，而改一条链的表头只应波及 `L` 个格子。
/// 这个比值是设计上就该有的，不是靠调参凑出来的。
///
/// 选项的默认值与校验在 `cli/` 里（那里有测试）；这里只负责跑。

///|
fn run_bench(opts : @cli.BenchOptions) -> Unit {
  let chains = opts.chains
  let length = opts.length
  let repeat = opts.repeat
  let total = chains * length
  println(
    "building " +
    @render.plural(chains, "independent chain") +
    " of " +
    @render.plural(length, "cell") +
    " (" +
    @render.plural(total, "cell") +
    ")",
  )

  // ---- 构造：第 m 条链在列 column_name(m)，第 1 行是常量，其余 =上一格+1 ----
  let entries : Array[(String, String)] = []
  let mut m = 0
  while m < chains {
    let col = @reference.column_name(m)
    let mut row = 1
    while row <= length {
      let key = col + row.to_string()
      let content = if row == 1 {
        "1"
      } else {
        "=" + col + (row - 1).to_string() + "+1"
      }
      entries.push((key, content))
      row = row + 1
    }
    m = m + 1
  }

  let wb = @engine.Workbook::new()
  match wb.set_many(entries) {
    Ok(_) => ()
    Err(_) => {
      println("error: could not build the benchmark sheet")
      return
    }
  }

  // ---- 全量重算：所有格子都是脏的 ----
  let full_start = @env.now()
  let full_trace = wb.recalculate()
  let full_ms = @env.now() - full_start

  // ---- 增量重算：只改第一条链的表头 ----
  let head_col = @reference.column_name(0)
  let head = head_col + "1"
  let mut best_cells = 0
  let mut best_ms : UInt64 = 0
  let mut first = true
  let mut i = 0
  while i < repeat {
    // 交替写两个不同的值，确保每次都真的产生一次变化
    let value = if i % 2 == 0 { "2" } else { "3" }
    match wb.set(head, value) {
      Ok(_) => ()
      Err(_) => {
        println("error: could not update the head cell")
        return
      }
    }
    let start = @env.now()
    let trace = wb.recalculate()
    let elapsed = @env.now() - start
    if first || elapsed < best_ms {
      best_ms = elapsed
      best_cells = trace.recomputed.length()
    }
    first = false
    i = i + 1
  }

  println("")
  println("full recalculation")
  println(
    "  " +
    full_trace.recomputed.length().to_string() +
    " cells in " +
    full_ms.to_string() +
    " ms",
  )
  println("incremental recalculation (one head changed)")
  println(
    "  " + best_cells.to_string() + " cells in " + best_ms.to_string() + " ms",
  )
  println("")
  // 格子数是**精确**的；耗时是单机测得、取重复中的最小值。
  println(
    "cells recomputed: " + @render.ratio_text(total, best_cells) + " fewer",
  )
  // 只有全量确实**测得比**增量慢时才报倍数。
  // 两者都是 1 ms（或都取到 0）时，比值的意义是"这个规模下测不出来"，
  // 而不是"一样快" —— 报成 1.0x 会让人以为没有提升。
  if best_ms > 0 && full_ms > best_ms {
    println(
      "wall clock:       " +
      @render.ratio_text(full_ms.to_int(), best_ms.to_int()) +
      " faster",
    )
  } else {
    println(
      "wall clock:       not measurable at this size (both runs fit in about a " +
      "millisecond); raise --length to measure it",
    )
  }
  println("")
  println(
    "The cell count is exact. The timings are from one machine, taking the\n" +
    "minimum of " +
    @render.plural(repeat, "run") +
    "; scheduling noise only ever makes a run\n" +
    "slower, so the minimum is the closest thing to a true cost.",
  )
}
