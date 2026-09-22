///|
/// 白盒测试：值类型、错误值、类型强制转换、数字解析与格式化。
///
/// 这一层是整个内核的地基，所以断言写得比别处密 ——
/// 电子表格的隐式转换规则是"看起来显然、实际很容易写错"的典型。

// ---------------------------------------------------------------- 错误字面量

///|
test "every error variant has a distinct spreadsheet literal" {
  let all : Array[CalcError] = [
    DivByZero,
    ValueType,
    Ref,
    Name,
    Num,
    NotAvailable,
    Cycle,
  ]
  assert_eq(all[0].literal(), "#DIV/0!")
  assert_eq(all[1].literal(), "#VALUE!")
  assert_eq(all[2].literal(), "#REF!")
  assert_eq(all[3].literal(), "#NAME?")
  assert_eq(all[4].literal(), "#NUM!")
  assert_eq(all[5].literal(), "#N/A")
  assert_eq(all[6].literal(), "#CYCLE!")
  // 字面量必须互不相同，否则从文本还原时会二义。
  for i in 0..<all.length() {
    for j in 0..<all.length() {
      if i != j {
        assert_true(all[i].literal() != all[j].literal())
      }
    }
  }
}

///|
test "error literals round-trip through parse and render" {
  let all : Array[CalcError] = [
    DivByZero,
    ValueType,
    Ref,
    Name,
    Num,
    NotAvailable,
    Cycle,
  ]
  for e in all {
    assert_true(CalcError::from_literal(e.literal()) is Some(v) && v == e)
  }
}

///|
test "error literal parsing is case-insensitive and trims whitespace" {
  assert_true(CalcError::from_literal("  #div/0!  ") is Some(DivByZero))
  assert_true(CalcError::from_literal("#value!") is Some(ValueType))
  assert_true(CalcError::from_literal("#CYCLE!") is Some(Cycle))
}

///|
test "unknown error literals are not turned into errors" {
  // 这条很重要：不能把普通文本当成错误值，否则用户输入 "#hello" 会变成错误。
  assert_true(CalcError::from_literal("#HELLO") is None)
  assert_true(CalcError::from_literal("") is None)
  assert_true(CalcError::from_literal("#DIV/0") is None)
}

// ---------------------------------------------------------------- 类型判定

///|
test "value kind predicates" {
  assert_true(num(1.0).is_number())
  assert_false(text("1").is_number())
  assert_true(Blank.is_blank())
  assert_false(num(0.0).is_blank())
  assert_true(err(Ref).is_error())
  assert_false(num(1.0).is_error())
}

// ---------------------------------------------------------------- 转数字

///|
test "as_number follows the spreadsheet coercion table" {
  assert_eq(num(2.5).as_number(), Ok(2.5))
  // 空值参与算术时当 0
  assert_eq(Blank.as_number(), Ok(0.0))
  // 逻辑值当 1 / 0
  assert_eq(boolean(true).as_number(), Ok(1.0))
  assert_eq(boolean(false).as_number(), Ok(0.0))
  // 文本若能解析为纯数字则用其数值
  assert_eq(text("12.5").as_number(), Ok(12.5))
  assert_eq(text("  -3  ").as_number(), Ok(-3.0))
  // 文本不能解析 → #VALUE!
  assert_eq(text("abc").as_number(), Err(ValueType))
  assert_eq(text("").as_number(), Err(ValueType))
  assert_eq(text("12abc").as_number(), Err(ValueType))
}

///|
test "as_number propagates errors instead of reporting a type error" {
  // 关键区分：#DIV/0! 经过 A1+1 仍然是 #DIV/0!，不能被改写成 #VALUE!。
  assert_eq(err(DivByZero).as_number(), Err(DivByZero))
  assert_eq(err(Ref).as_number(), Err(Ref))
}

// ---------------------------------------------------------------- 转文本

///|
test "as_text never fails, because every value has a text form" {
  assert_eq(text("hi").as_text(), "hi")
  assert_eq(Blank.as_text(), "")
  assert_eq(num(1.0).as_text(), "1")
  assert_eq(num(1.5).as_text(), "1.5")
  assert_eq(num(-2.0).as_text(), "-2")
  assert_eq(boolean(true).as_text(), "TRUE")
  assert_eq(boolean(false).as_text(), "FALSE")
  assert_eq(err(NotAvailable).as_text(), "#N/A")
}

// ---------------------------------------------------------------- 转布尔

///|
test "as_bool follows the spreadsheet coercion table" {
  assert_eq(boolean(true).as_bool(), Ok(true))
  assert_eq(num(0.0).as_bool(), Ok(false))
  assert_eq(num(0.5).as_bool(), Ok(true))
  assert_eq(num(-1.0).as_bool(), Ok(true))
  assert_eq(Blank.as_bool(), Ok(false))
  assert_eq(text("true").as_bool(), Ok(true))
  assert_eq(text("FALSE").as_bool(), Ok(false))
  assert_eq(text(" True ").as_bool(), Ok(true))
  assert_eq(text("yes").as_bool(), Err(ValueType))
  assert_eq(err(Cycle).as_bool(), Err(Cycle))
}

// ---------------------------------------------------------------- 跨类型比较

///|
test "compare orders numbers before text before booleans" {
  // 电子表格的排序规则：数字 < 文本 < 逻辑值。
  assert_true(compare(num(999.0), text("a")) < 0)
  assert_true(compare(text("z"), boolean(false)) < 0)
  assert_true(compare(num(1.0), boolean(false)) < 0)
}

///|
test "compare within a type" {
  assert_true(compare(num(1.0), num(2.0)) < 0)
  assert_eq(compare(num(2.0), num(2.0)), 0)
  assert_true(compare(num(3.0), num(2.0)) > 0)
  assert_true(compare(text("a"), text("b")) < 0)
  assert_eq(compare(text("a"), text("a")), 0)
  // 前缀短的排前面
  assert_true(compare(text("ab"), text("abc")) < 0)
  // false < true
  assert_true(compare(boolean(false), boolean(true)) < 0)
}

///|
test "blank takes the shape of whatever it is compared against" {
  // 空值和数字比当 0，和文本比当 ""，和逻辑值比当 false。
  assert_eq(compare(Blank, num(0.0)), 0)
  assert_eq(compare(Blank, text("")), 0)
  assert_eq(compare(Blank, boolean(false)), 0)
  assert_true(compare(Blank, num(1.0)) < 0)
  assert_true(compare(Blank, text("a")) < 0)
}

///|
test "comparing errors is deterministic rather than an error" {
  assert_eq(compare(err(Ref), err(Ref)), 0)
  assert_true(compare(err(DivByZero), err(Ref)) != 0)
  // 错误值排在所有普通值之后
  assert_true(compare(num(1.0), err(Ref)) < 0)
  assert_true(compare(text("z"), err(Ref)) < 0)
  assert_true(compare(boolean(true), err(Ref)) < 0)
}

// ---------------------------------------------------------------- 数字格式化

///|
test "format_number drops the trailing .0 on integral values" {
  assert_eq(format_number(0.0), "0")
  assert_eq(format_number(1.0), "1")
  assert_eq(format_number(-1.0), "-1")
  assert_eq(format_number(1000000.0), "1000000")
  // -0 归一成 0，否则 =-0 会显示成 "-0"
  assert_eq(format_number(-0.0), "0")
}

///|
test "format_number keeps the fraction on non-integral values" {
  assert_eq(format_number(1.5), "1.5")
  assert_eq(format_number(-2.25), "-2.25")
  assert_eq(format_number(0.5), "0.5")
}

///|
test "format_number maps non-finite values to spreadsheet errors" {
  // 电子表格里 NaN / Inf 本就该是错误，而不是一个能打印的数字。
  assert_eq(format_number(0.0 / 0.0), "#NUM!")
  assert_eq(format_number(1.0 / 0.0), "#DIV/0!")
  assert_eq(format_number(-1.0 / 0.0), "#DIV/0!")
}

// ---------------------------------------------------------------- 整数转文本

///|
test "int_to_string handles zero, positives and negatives" {
  assert_eq(int_to_string(0), "0")
  assert_eq(int_to_string(7), "7")
  assert_eq(int_to_string(10), "10")
  assert_eq(int_to_string(1000000), "1000000")
  assert_eq(int_to_string(-1), "-1")
  assert_eq(int_to_string(-42), "-42")
  assert_eq(int_to_string(-1000000), "-1000000")
}

// ---------------------------------------------------------------- 数字解析

///|
test "parse_number accepts plain decimal forms" {
  assert_eq(parse_number("0"), Some(0.0))
  assert_eq(parse_number("12"), Some(12.0))
  assert_eq(parse_number("+5"), Some(5.0))
  assert_eq(parse_number("-3"), Some(-3.0))
  assert_eq(parse_number("12.5"), Some(12.5))
  assert_eq(parse_number(".5"), Some(0.5))
  assert_eq(parse_number("5."), Some(5.0))
  assert_eq(parse_number("  12.5  "), Some(12.5))
}

///|
test "parse_number accepts scientific notation" {
  assert_eq(parse_number("1e3"), Some(1000.0))
  assert_eq(parse_number("1E3"), Some(1000.0))
  assert_eq(parse_number("1e+3"), Some(1000.0))
  assert_eq(parse_number("1e-3"), Some(0.001))
  assert_eq(parse_number("-2.5e2"), Some(-250.0))
}

///|
test "parse_number rejects anything that is not a pure number" {
  // 刻意比 Excel 严格：Excel 会把 "12abc" 当 12，那套规则难以预测也难以测试。
  assert_true(parse_number("") is None)
  assert_true(parse_number("   ") is None)
  assert_true(parse_number("abc") is None)
  assert_true(parse_number("12abc") is None)
  assert_true(parse_number("1.2.3") is None)
  assert_true(parse_number(".") is None)
  assert_true(parse_number("-") is None)
  assert_true(parse_number("+") is None)
  assert_true(parse_number("1e") is None)
  assert_true(parse_number("1e+") is None)
  assert_true(parse_number("0x10") is None)
  assert_true(parse_number("1,000") is None)
}

///|
test "parse_number and format_number round-trip on tidy values" {
  let values : Array[Double] = [0.0, 1.0, -1.0, 12.5, -0.25, 1000.0]
  for v in values {
    let rendered = format_number(v)
    assert_eq(parse_number(rendered), Some(v))
  }
}

// ---------------------------------------------------------------- ASCII 大写

///|
test "ascii_upper only touches ASCII letters" {
  assert_eq(ascii_upper("true"), "TRUE")
  assert_eq(ascii_upper("True"), "TRUE")
  assert_eq(ascii_upper("#div/0!"), "#DIV/0!")
  // 中文没有大小写，必须原样保留
  assert_eq(ascii_upper("中文abc"), "中文ABC")
  assert_eq(ascii_upper(""), "")
}
