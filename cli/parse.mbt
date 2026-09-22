///|
/// 命令行解析：把 `argv[1..]` 变成一条**明确的意图或一条明确的错误**。
///
/// 这一层不碰 I/O、不碰引擎，所以可以被离线断言。
/// 它只回答两个问题：用户想干什么？说得对不对？

///|
/// 一条已解析的命令。
pub(all) enum Command {
  /// 求值一张表：`(是否打印重算轨迹, [(单元格, 内容)])`
  Eval(Bool, Array[(String, String)])
  Demo
  Example
  Bench(BenchOptions)
  /// 要打印的帮助；`None` 表示顶层用法
  Help(String?)
  /// 用户输入有误：`(错误说明, 该打印的用法)`
  Bad(String, String)
}

///|
/// 基准测试的规模参数。
pub(all) struct BenchOptions {
  chains : Int
  length : Int
  repeat : Int
}

///|
/// 基准的默认规模。这个量级是为了让耗时能被毫秒级时钟分辨出来：
/// 规模太小的话全量与增量都会落在同一毫秒里，比值就没有意义。
pub fn default_bench_options() -> BenchOptions {
  { chains: 10, length: 1000, repeat: 5, }
}

///|
/// 一次基准最多构造多少格子。
///
/// 为什么需要：`chains * length` 是 32 位整数乘法，给两个大数就会**静默回绕**
/// 成一个负数（与之前 `A1:XFD1048576` 溢出到 0 是同一类 bug）。
/// 与其让它算出一个荒谬的「格子数」，不如明确拒绝。
/// 上限取 100 万：默认规模是 1 万，已经能跑出稳定的对比。
pub let max_bench_cells : Int = 1000000

///|
/// 解析 `argv[1..]`。
pub fn parse(args : Array[String]) -> Command {
  if args.length() == 0 {
    return Help(None)
  }
  let head = args[0]
  let rest = drop_first(args)
  if head == "eval" {
    return parse_eval(rest)
  }
  if head == "demo" {
    if rest.length() == 0 {
      return Demo
    }
    if is_help_flag(rest[0]) {
      return Help(Some("demo"))
    }
    return Bad("demo takes no arguments, but got: " + rest[0], usage_demo())
  }
  if head == "example" {
    if rest.length() == 0 {
      return Example
    }
    if is_help_flag(rest[0]) {
      return Help(Some("example"))
    }
    return Bad(
      "example takes no arguments, but got: " + rest[0],
      usage_example(),
    )
  }
  if head == "bench" {
    return parse_bench(rest)
  }
  if head == "help" {
    return Help(help_topic(rest))
  }
  if is_help_flag(head) {
    return Help(None)
  }
  // 裸写 `CELL=CONTENT` 等价于 `eval`，这是常用的简写。
  // 但**只有真的含 `=`** 才这样解释：否则 `sheetcore nosuchcmd` 会被当成
  // 单元格内容，报出「expected CELL=CONTENT」这种答非所问的错。
  if contains_char(head, '=') {
    return parse_eval(args)
  }
  Bad("unknown command: " + head, usage_top())
}

///|
/// `help` 后面跟的命令名，认得就给它专属帮助，认不得就退回顶层用法。
fn help_topic(rest : Array[String]) -> String? {
  if rest.length() == 0 {
    return None
  }
  let topic = rest[0]
  if topic == "eval" ||
    topic == "demo" ||
    topic == "example" ||
    topic == "bench" {
    return Some(topic)
  }
  None
}

///|
/// 解析 `eval` 的参数。
fn parse_eval(args : Array[String]) -> Command {
  let entries : Array[(String, String)] = []
  let mut show_trace = false
  for a in args {
    if a == "--trace" {
      show_trace = true
    } else if is_help_flag(a) {
      return Help(Some("eval"))
    } else {
      match split_first(a, '=') {
        Some(pair) => entries.push(pair)
        None => return Bad("expected CELL=CONTENT but got: " + a, usage_eval())
      }
    }
  }
  if entries.length() == 0 {
    return Bad("nothing to evaluate", usage_eval())
  }
  Eval(show_trace, entries)
}

///|
/// 解析 `bench` 的选项。
fn parse_bench(args : Array[String]) -> Command {
  let d = default_bench_options()
  let mut chains = d.chains
  let mut length = d.length
  let mut repeat = d.repeat
  for a in args {
    if is_help_flag(a) {
      return Help(Some("bench"))
    }
    let pair = match split_first(a, '=') {
      Some(p) => p
      None => return Bad("expected --option=value but got: " + a, usage_bench())
    }
    let value = match parse_int(pair.1) {
      Some(n) => n
      None => return Bad("not an integer: " + pair.1, usage_bench())
    }
    if pair.0 == "--chains" {
      chains = value
    } else if pair.0 == "--length" {
      length = value
    } else if pair.0 == "--repeat" {
      repeat = value
    } else {
      return Bad("unknown option: " + pair.0, usage_bench())
    }
  }
  // 逐个选项单独报错：旧版无论哪个越界，都会把三个选项一起念一遍。
  if chains < 1 {
    return Bad(
      "--chains must be at least 1, got " + chains.to_string(),
      usage_bench(),
    )
  }
  if length < 1 {
    return Bad(
      "--length must be at least 1, got " + length.to_string(),
      usage_bench(),
    )
  }
  if repeat < 1 {
    return Bad(
      "--repeat must be at least 1, got " + repeat.to_string(),
      usage_bench(),
    )
  }
  // 用 Int64 相乘，避免 32 位回绕成负数后蒙混过关。
  let total64 = chains.to_int64() * length.to_int64()
  if total64 > max_bench_cells.to_int64() {
    return Bad(
      "--chains * --length would build " +
      total64.to_string() +
      " cells; the cap is " +
      max_bench_cells.to_string(),
      usage_bench(),
    )
  }
  Bench({ chains, length, repeat, })
}

///|
/// 是否是要求帮助的开关。
fn is_help_flag(s : String) -> Bool {
  s == "--help" || s == "-h"
}

///|
/// 顶层用法。
pub fn usage_top() -> String {
  "SheetCore — a spreadsheet calculation core in pure MoonBit\n" +
  "\n" +
  "Usage:\n" +
  "  sheetcore eval [--trace] CELL=CONTENT ...   evaluate a sheet and print it\n" +
  "  sheetcore demo                              incremental recalculation, step by step\n" +
  "  sheetcore example                           a realistic quotation sheet\n" +
  "  sheetcore bench [--chains=N] [--length=L] [--repeat=R]\n" +
  "                                              incremental vs full recalculation\n" +
  "  sheetcore help [COMMAND]                    this text, or one command's options\n" +
  "\n" +
  "  sheetcore CELL=CONTENT ...                  shorthand for `sheetcore eval`\n" +
  "\n" +
  "Cell content starting with '=' is a formula; anything else is a literal.\n" +
  "Only the first '=' splits cell from content, so B1==A1+A2 works."
}

///|
/// `eval` 的用法。
pub fn usage_eval() -> String {
  "Usage: sheetcore eval [--trace] CELL=CONTENT ...\n" +
  "\n" +
  "  --trace     also print which cells were recomputed, and in what order\n" +
  "\n" +
  "Each argument is one cell: its name, then '=', then its content.\n" +
  "Only the first '=' splits, so B1==A1+A2 gives cell B1 the formula =A1+A2.\n" +
  "Content starting with '=' is a formula; anything else is a literal.\n" +
  "\n" +
  "Example: sheetcore eval A1=10 A2=20 B1==A1+A2"
}

///|
/// `demo` 的用法。
pub fn usage_demo() -> String {
  "Usage: sheetcore demo\n" +
  "\n" +
  "Builds a small sheet, changes one cell, and prints how many cells were\n" +
  "recalculated. Takes no arguments."
}

///|
/// `example` 的用法。
pub fn usage_example() -> String {
  "Usage: sheetcore example\n" +
  "\n" +
  "Builds a quotation sheet and changes one quantity, to show which cells a\n" +
  "real edit touches. Takes no arguments."
}

///|
/// `bench` 的用法。
pub fn usage_bench() -> String {
  "Usage: sheetcore bench [--chains=N] [--length=L] [--repeat=R]\n" +
  "\n" +
  "  --chains=N   independent chains                      (default " +
  default_bench_options().chains.to_string() +
  ")\n" +
  "  --length=L   cells per chain                         (default " +
  default_bench_options().length.to_string() +
  ")\n" +
  "  --repeat=R   timed runs; the minimum is reported     (default " +
  default_bench_options().repeat.to_string() +
  ")\n" +
  "\n" +
  "Builds --chains independent chains of --length cells, then times a full\n" +
  "recalculation against an incremental one. The cell counts are exact; the\n" +
  "timings come from this machine."
}

///|
/// 按主题取用法文本。`None` 取顶层。
pub fn usage_for(topic : String?) -> String {
  match topic {
    None => usage_top()
    Some("eval") => usage_eval()
    Some("demo") => usage_demo()
    Some("example") => usage_example()
    Some("bench") => usage_bench()
    Some(other) => "no help for '" + other + "'\n\n" + usage_top()
  }
}

///|
/// 在**第一个** `sep` 处切分。返回 `None` 表示没有分隔符。
pub fn split_first(s : StringView, sep : Char) -> (String, String)? {
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

///|
/// 是否含有某个字符。
pub fn contains_char(s : StringView, c : Char) -> Bool {
  for ch in s {
    if ch == c {
      return true
    }
  }
  false
}

///|
/// 去掉第一个元素。
pub fn drop_first(items : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut i = 1
  while i < items.length() {
    out.push(items[i])
    i = i + 1
  }
  out
}

///|
/// 解析十进制非负整数。前导/尾随空白忽略，其余字符必须全是数字。
pub fn parse_int(s : StringView) -> Int? {
  let trimmed = s.trim()
  if trimmed.length() == 0 {
    return None
  }
  let mut value = 0
  for ch in trimmed {
    if ch < '0' || ch > '9' {
      return None
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
  }
  Some(value)
}
