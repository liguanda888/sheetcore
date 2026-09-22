///|
/// 白盒测试：命令行解析。
///
/// 这些规则原来长在 `cmd/main` 里，没有测试，于是攒下了四条缺陷 ——
/// 每条都在下面钉住。特别是第一条：拼错的子命令曾经被当成单元格内容。

///|
test "an unknown command is not mistaken for cell content" {
  // 这是修复前的实际输出：
  //     $ sheetcore nosuchcmd
  //     error: expected CELL=CONTENT but got: nosuchcmd
  // 子命令写错却报「单元格格式不对」，是答非所问。
  match parse(["nosuchcmd"]) {
    Bad(msg, usage) => {
      assert_eq(msg, "unknown command: nosuchcmd")
      assert_eq(usage, usage_top())
    }
    _ => abort("expected Bad")
  }
}

///|
test "a bare CELL=CONTENT is still shorthand for eval" {
  match parse(["A1=1", "B1==A1+1"]) {
    Eval(trace, entries) => {
      assert_eq(trace, false)
      assert_eq(entries.length(), 2)
      assert_eq(entries[0].0, "A1")
      assert_eq(entries[0].1, "1")
    }
    _ => abort("expected Eval")
  }
}

///|
test "eval splits at the first '=' only" {
  match parse(["eval", "B1==A1+A2"]) {
    Eval(_, entries) => {
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].0, "B1")
      // 第二个 '=' 属于公式本身，不能被吃掉
      assert_eq(entries[0].1, "=A1+A2")
    }
    _ => abort("expected Eval")
  }
}

///|
test "eval passes an empty cell name through to the engine" {
  // 单元格名是否合法由引擎判定（它才知道 A1 记法的规则），
  // 这里只负责切分。职责不重叠，所以 `=1` 会被原样传下去。
  match parse(["eval", "=1"]) {
    Eval(_, entries) => {
      assert_eq(entries[0].0, "")
      assert_eq(entries[0].1, "1")
    }
    _ => abort("expected Eval")
  }
}

///|
test "--trace turns on the trace, in any position" {
  match parse(["eval", "--trace", "A1=1"]) {
    Eval(trace, entries) => {
      assert_eq(trace, true)
      assert_eq(entries.length(), 1)
    }
    _ => abort("expected Eval")
  }
  match parse(["eval", "A1=1", "--trace"]) {
    Eval(trace, _) => assert_eq(trace, true)
    _ => abort("expected Eval")
  }
}

///|
test "eval with nothing to evaluate asks for input" {
  match parse(["eval"]) {
    Bad(msg, usage) => {
      assert_eq(msg, "nothing to evaluate")
      assert_eq(usage, usage_eval())
    }
    _ => abort("expected Bad")
  }
}

///|
test "eval rejects an argument that is not CELL=CONTENT" {
  match parse(["eval", "A1=1", "--nope"]) {
    Bad(msg, _) => assert_eq(msg, "expected CELL=CONTENT but got: --nope")
    _ => abort("expected Bad")
  }
}

///|
test "no arguments shows the top-level usage" {
  match parse([]) {
    Help(None) => ()
    _ => abort("expected Help(None)")
  }
  for flag in ["--help", "-h", "help"] {
    match parse([flag]) {
      Help(None) => ()
      _ => abort("expected Help(None) for " + flag)
    }
  }
}

///|
test "every subcommand answers --help" {
  // 修复前 `bench --help` 报「expected --option=value but got: --help」，
  // `eval --help` 报「expected CELL=CONTENT」—— 想求帮助却挨一记报错。
  let cases : Array[(String, String)] = [
    ("eval", "eval"),
    ("demo", "demo"),
    ("example", "example"),
    ("bench", "bench"),
  ]
  for pair in cases {
    match parse([pair.0, "--help"]) {
      Help(Some(topic)) => assert_eq(topic, pair.1)
      _ => abort("expected Help for " + pair.0)
    }
    match parse([pair.0, "-h"]) {
      Help(Some(topic)) => assert_eq(topic, pair.1)
      _ => abort("expected Help for " + pair.0 + " -h")
    }
  }
}

///|
test "help COMMAND gives that command's usage, and an unknown one falls back" {
  match parse(["help", "bench"]) {
    Help(Some("bench")) => ()
    _ => abort("expected Help(Some(bench))")
  }
  match parse(["help", "nosuchcmd"]) {
    Help(None) => ()
    _ => abort("expected Help(None)")
  }
}

///|
test "--version is recognised, but -v is not guessed at" {
  for flag in ["--version", "-V"] {
    match parse([flag]) {
      Version => ()
      _ => abort("expected Version for " + flag)
    }
  }
  // 只认 `-V`。`-v` 常常是 verbose，猜错比不认更烦人。
  match parse(["-v"]) {
    Bad(msg, _) => assert_eq(msg, "unknown command: -v")
    _ => abort("expected Bad for -v")
  }
}

///|
test "demo and example reject extra arguments instead of ignoring them" {
  // 修复前 `demo extra` 会照常跑完演示，多余参数被静默吞掉。
  match parse(["demo"]) {
    Demo => ()
    _ => abort("expected Demo")
  }
  match parse(["demo", "extra"]) {
    Bad(msg, usage) => {
      assert_eq(msg, "demo takes no arguments, but got: extra")
      assert_eq(usage, usage_demo())
    }
    _ => abort("expected Bad")
  }
  match parse(["example"]) {
    Example => ()
    _ => abort("expected Example")
  }
  match parse(["example", "extra"]) {
    Bad(msg, _) => assert_eq(msg, "example takes no arguments, but got: extra")
    _ => abort("expected Bad")
  }
}

///|
test "bench defaults are the documented ones" {
  match parse(["bench"]) {
    Bench(o) => {
      assert_eq(o.chains, 10)
      assert_eq(o.length, 1000)
      assert_eq(o.repeat, 5)
    }
    _ => abort("expected Bench")
  }
}

///|
test "bench reads its three options" {
  match parse(["bench", "--chains=2", "--length=3", "--repeat=4"]) {
    Bench(o) => {
      assert_eq(o.chains, 2)
      assert_eq(o.length, 3)
      assert_eq(o.repeat, 4)
    }
    _ => abort("expected Bench")
  }
}

///|
test "bench names the option that is actually wrong" {
  // 修复前无论哪个越界，都报「--chains, --length and --repeat must all be at least 1」，
  // 三个都念一遍，读者还得自己排查是哪一个。
  match parse(["bench", "--length=0"]) {
    Bad(msg, _) => assert_eq(msg, "--length must be at least 1, got 0")
    _ => abort("expected Bad")
  }
  match parse(["bench", "--chains=0"]) {
    Bad(msg, _) => assert_eq(msg, "--chains must be at least 1, got 0")
    _ => abort("expected Bad")
  }
  match parse(["bench", "--repeat=0"]) {
    Bad(msg, _) => assert_eq(msg, "--repeat must be at least 1, got 0")
    _ => abort("expected Bad")
  }
}

///|
test "bench rejects malformed and unknown options" {
  match parse(["bench", "--chains"]) {
    Bad(msg, _) => assert_eq(msg, "expected --option=value but got: --chains")
    _ => abort("expected Bad")
  }
  match parse(["bench", "--chains=abc"]) {
    Bad(msg, _) => assert_eq(msg, "not an integer: abc")
    _ => abort("expected Bad")
  }
  match parse(["bench", "--nope=1"]) {
    Bad(msg, _) => assert_eq(msg, "unknown option: --nope")
    _ => abort("expected Bad")
  }
}

///|
test "bench refuses a size that would overflow 32-bit multiplication" {
  // `chains * length` 是 32 位整数乘法。10 万 × 10 万 = 100 亿，
  // 回绕之后会变成一个负数，于是「格子数」荒谬但不报错 ——
  // 与之前 `A1:XFD1048576` 溢出到 0 是同一类 bug。
  match parse(["bench", "--chains=100000", "--length=100000"]) {
    Bad(msg, _) =>
      assert_eq(
        msg, "--chains * --length would build 10000000000 cells; the cap is 1000000",
      )
    _ => abort("expected Bad")
  }
}

///|
test "bench allows exactly the cap" {
  // 边界：1000 × 1000 = 1000000，正好等于上限，应当通过。
  match parse(["bench", "--chains=1000", "--length=1000"]) {
    Bench(o) => {
      assert_eq(o.chains, 1000)
      assert_eq(o.length, 1000)
    }
    _ => abort("expected Bench at the cap")
  }
}

///|
test "the cap is one over the boundary" {
  match parse(["bench", "--chains=1000", "--length=1001"]) {
    Bad(_, _) => ()
    _ => abort("expected Bad just over the cap")
  }
}

///|
test "usage_for dispatches to the matching text" {
  assert_eq(usage_for(None), usage_top())
  assert_eq(usage_for(Some("eval")), usage_eval())
  assert_eq(usage_for(Some("demo")), usage_demo())
  assert_eq(usage_for(Some("example")), usage_example())
  assert_eq(usage_for(Some("bench")), usage_bench())
}

///|
test "every usage text is non-empty" {
  assert_true(usage_top().length() > 0)
  assert_true(usage_eval().length() > 0)
  assert_true(usage_demo().length() > 0)
  assert_true(usage_example().length() > 0)
  assert_true(usage_bench().length() > 0)
}

///|
test "bench usage states the defaults it actually uses" {
  // 帮助文本里的默认值是从 default_bench_options() 拼出来的，
  // 所以改了默认值不会让文档悄悄过期。
  let u = usage_bench()
  assert_true(contains_substring(u, "default 10"))
  assert_true(contains_substring(u, "default 1000"))
  assert_true(contains_substring(u, "default 5"))
}

///|
test "split_first splits at the first occurrence only" {
  match split_first("a=b=c", '=') {
    Some(pair) => {
      assert_eq(pair.0, "a")
      assert_eq(pair.1, "b=c")
    }
    None => abort("expected Some")
  }
  match split_first("=x", '=') {
    Some(pair) => {
      assert_eq(pair.0, "")
      assert_eq(pair.1, "x")
    }
    None => abort("expected Some")
  }
  match split_first("none", '=') {
    None => ()
    Some(_) => abort("expected None")
  }
}

///|
test "contains_char finds a character anywhere" {
  assert_eq(contains_char("A1=1", '='), true)
  assert_eq(contains_char("A1=1", 'x'), false)
  assert_eq(contains_char("", '='), false)
  assert_eq(contains_char("=", '='), true)
}

///|
test "drop_first removes exactly one element" {
  let r = drop_first(["a", "b", "c"])
  assert_eq(r.length(), 2)
  assert_eq(r[0], "b")
  assert_eq(r[1], "c")
  assert_eq(drop_first(["a"]).length(), 0)
  assert_eq(drop_first([]).length(), 0)
}

///|
test "parse_int accepts digits and rejects everything else" {
  match parse_int("123") {
    Some(n) => assert_eq(n, 123)
    None => abort("expected Some")
  }
  match parse_int(" 42 ") {
    Some(n) => assert_eq(n, 42)
    None => abort("expected Some for padded input")
  }
  assert_eq(parse_int(""), None)
  assert_eq(parse_int("  "), None)
  assert_eq(parse_int("1a"), None)
  assert_eq(parse_int("-1"), None)
  assert_eq(parse_int("1.5"), None)
  match parse_int("0") {
    Some(n) => assert_eq(n, 0)
    None => abort("expected Some(0)")
  }
}

///|
/// 测试用：子串判定。（core 的字符串查找接口不固定，这里只用得到这一个方向。）
fn contains_substring(haystack : String, needle : String) -> Bool {
  let h : Array[Char] = []
  for ch in haystack {
    h.push(ch)
  }
  let n : Array[Char] = []
  for ch in needle {
    n.push(ch)
  }
  if n.length() == 0 {
    return true
  }
  if n.length() > h.length() {
    return false
  }
  let mut i = 0
  while i + n.length() <= h.length() {
    let mut j = 0
    let mut all = true
    while j < n.length() {
      if h[i + j] != n[j] {
        all = false
        break
      }
      j = j + 1
    }
    if all {
      return true
    }
    i = i + 1
  }
  false
}
