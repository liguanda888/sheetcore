///|
/// 白盒测试：比值渲染。

///|
test "ratio_text keeps one decimal" {
  assert_eq(ratio_text(100, 10), "10.0x")
  assert_eq(ratio_text(2000, 1000), "2.0x")
  assert_eq(ratio_text(1000, 1000), "1.0x")
}

///|
test "ratio_text rounds down to one decimal instead of printing a long tail" {
  // 10 / 6 = 1.666…，一位小数取 1.6
  assert_eq(ratio_text(10, 6), "1.6x")
  // 100 / 3 = 33.33…，一位小数取 33.3
  assert_eq(ratio_text(100, 3), "33.3x")
}

///|
test "ratio_text reports n/a when the divisor is zero or negative" {
  // 这是它存在的理由：`bench` 里增量耗时可能取到 0（时钟分辨率不够），
  // 那时比值没有意义，必须说出来，而不是打印 0.0x 或崩掉。
  assert_eq(ratio_text(100, 0), "n/a")
  assert_eq(ratio_text(100, -5), "n/a")
}

///|
test "ratio_text can report a ratio below one" {
  // 增量比全量还慢时会落到这里（规模太小、噪声大）。不掩饰。
  assert_eq(ratio_text(5, 10), "0.5x")
}

///|
test "plural says 1 run, not 1 runs" {
  // `--repeat=1` 是 CI 里的实际用法，所以这条路径每次 CI 都会走到。
  assert_eq(plural(1, "run"), "1 run")
  assert_eq(plural(2, "run"), "2 runs")
  assert_eq(plural(5, "run"), "5 runs")
  assert_eq(plural(0, "run"), "0 runs")
}

///|
test "plural covers the other nouns bench prints" {
  assert_eq(plural(1, "chain"), "1 chain")
  assert_eq(plural(10, "chain"), "10 chains")
  assert_eq(plural(1, "cell"), "1 cell")
  assert_eq(plural(1000, "cell"), "1000 cells")
}
