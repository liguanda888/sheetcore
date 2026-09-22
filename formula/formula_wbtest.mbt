///|
/// 白盒测试：词法分析、语法分析、优先级、AST 辅助函数。
///
/// 重点覆盖三类容易错的地方：
/// 1. **歧义消解** —— `A1` 是引用，`LOG10` 是函数名，`TRUE` 是逻辑值
/// 2. **反直觉的优先级** —— `-2^2` 在电子表格里是 4 不是 -4
/// 3. **身份与回显分离** —— `$A$1` 与 `A1` 是同一个格子

// ================================================================ 词法分析

///|
test "lexes numbers, including exponent forms" {
  assert_eq(tokenize("1"), Ok([Number(1.0), Eof]))
  assert_eq(tokenize("1.5"), Ok([Number(1.5), Eof]))
  assert_eq(tokenize(".5"), Ok([Number(0.5), Eof]))
  assert_eq(tokenize("1e3"), Ok([Number(1000.0), Eof]))
  assert_eq(tokenize("1E-3"), Ok([Number(0.001), Eof]))
}

///|
test "an incomplete exponent is split into a number and a name" {
  // `2E` 里的 E 不是一个残缺的指数，而是一个名字 —— 否则会报"非法数字"，
  // 而用户可能真的想让 E 当函数名的一部分。
  assert_eq(tokenize("2E"), Ok([Number(2.0), Ident("E"), Eof]))
  // 但 `2E3` 是完整的指数
  assert_eq(tokenize("2E3"), Ok([Number(2000.0), Eof]))
}

///|
test "lexes string literals with doubled-quote escaping" {
  assert_eq(tokenize("\"hi\""), Ok([Str("hi"), Eof]))
  assert_eq(tokenize("\"\""), Ok([Str(""), Eof]))
  // "" 表示一个真正的引号
  assert_eq(tokenize("\"a\"\"b\""), Ok([Str("a\"b"), Eof]))
}

///|
test "an unterminated string is an error, not a silent literal" {
  assert_true(tokenize("\"abc") is Err(_))
}

///|
test "disambiguates cell references from function names" {
  // 唯一的判据是后面跟不跟 '('
  assert_eq(
    tokenize("A1"),
    Ok([Ref(@reference.CellRef::parse("A1").unwrap()), Eof]),
  )
  assert_eq(
    tokenize("$A$1"),
    Ok([Ref(@reference.CellRef::parse("$A$1").unwrap()), Eof]),
  )
  // LOG10 形如引用（字母+数字）却是函数
  assert_eq(
    tokenize("LOG10(2)"),
    Ok([Ident("LOG10"), LParen, Number(2.0), RParen, Eof]),
  )
  // 名字一律大写化，函数名因此大小写不敏感
  assert_eq(
    tokenize("sum(1)"),
    Ok([Ident("SUM"), LParen, Number(1.0), RParen, Eof]),
  )
}

///|
test "lexes cross-sheet references including quoted sheet names" {
  assert_eq(
    tokenize("Sheet2!A1"),
    Ok([Ref(@reference.CellRef::parse("Sheet2!A1").unwrap()), Eof]),
  )
  // 表名里的空格必须被保留 —— 因此空格不能当作引用候选串的分隔符
  assert_eq(
    tokenize("'My Sheet'!A1"),
    Ok([Ref(@reference.CellRef::parse("'My Sheet'!A1").unwrap()), Eof]),
  )
}

///|
test "lexes booleans and error literals as their own kinds" {
  assert_eq(tokenize("TRUE"), Ok([BoolLit(true), Eof]))
  assert_eq(tokenize("false"), Ok([BoolLit(false), Eof]))
  assert_eq(tokenize("#REF!"), Ok([ErrorLit(@value.Ref), Eof]))
  assert_eq(tokenize("#div/0!"), Ok([ErrorLit(@value.DivByZero), Eof]))
  assert_true(tokenize("#NOPE") is Err(_))
}

///|
test "lexes every operator and punctuation mark" {
  assert_eq(
    tokenize("+-*/^&%,:()"),
    Ok([
      Plus,
      Minus,
      Star,
      Slash,
      Caret,
      Amp,
      Percent,
      Comma,
      Colon,
      LParen,
      RParen,
      Eof,
    ]),
  )
  // `<>` 必须整体识别为"不等于"：`=<>` 是等号加不等号，
  // 而不是等号加小于加大于。
  assert_eq(tokenize("=<>"), Ok([EqOp, NeOp, Eof]))
  assert_eq(tokenize("<>"), Ok([NeOp, Eof]))
  assert_eq(tokenize("<="), Ok([LeOp, Eof]))
  assert_eq(tokenize(">="), Ok([GeOp, Eof]))
}

///|
test "a colon between references is a range separator, not a sheet prefix" {
  // 表名前缀已经被引用分支吃掉了，剩下的 ':' 只能属于区域
  assert_eq(
    tokenize("A1:B2"),
    Ok([
      Ref(@reference.CellRef::parse("A1").unwrap()),
      Colon,
      Ref(@reference.CellRef::parse("B2").unwrap()),
      Eof,
    ]),
  )
}

// ================================================================ 语法分析

///|
fn parsed(src : String) -> Expr {
  match parse(src) {
    Ok(e) => e
    Err(ParseError(msg, pos)) =>
      abort(
        src + " 应该能解析，却报错：" + msg + " @" + pos.to_string(),
      )
  }
}

///|
test "parses literals and references" {
  assert_eq(parsed("1"), NumberLit(1.0))
  assert_eq(parsed("\"hi\""), TextLit("hi"))
  assert_eq(parsed("TRUE"), BoolLit(true))
  assert_eq(parsed("A1"), Ref(@reference.CellRef::parse("A1").unwrap()))
}

///|
test "multiplication binds tighter than addition" {
  assert_eq(
    parsed("1+2*3"),
    Binary(Add, NumberLit(1.0), Binary(Mul, NumberLit(2.0), NumberLit(3.0))),
  )
  // 括号改变结合
  assert_eq(
    parsed("(1+2)*3"),
    Binary(Mul, Binary(Add, NumberLit(1.0), NumberLit(2.0)), NumberLit(3.0)),
  )
}

///|
test "unary minus binds tighter than power, matching spreadsheets" {
  // `-2^2` 在电子表格里是 (-2)^2 = 4，而不是 -(2^2) = -4。
  // 这与大多数编程语言相反 —— 所以用结构断言把它钉住，而不是靠注释。
  assert_eq(
    parsed("-2^2"),
    Binary(Pow, Unary(Neg, NumberLit(2.0)), NumberLit(2.0)),
  )
  // 对照：想表达 -(2^2) 必须显式加括号
  assert_eq(
    parsed("-(2^2)"),
    Unary(Neg, Binary(Pow, NumberLit(2.0), NumberLit(2.0))),
  )
}

///|
test "power is right-associative" {
  assert_eq(
    parsed("2^3^2"),
    Binary(Pow, NumberLit(2.0), Binary(Pow, NumberLit(3.0), NumberLit(2.0))),
  )
}

///|
test "a negative exponent is parsed as a unary inside the power" {
  assert_eq(
    parsed("2^-3"),
    Binary(Pow, NumberLit(2.0), Unary(Neg, NumberLit(3.0))),
  )
}

///|
test "percent is a postfix unary operator" {
  assert_eq(parsed("50%"), Unary(Percent, NumberLit(50.0)))
  // 后缀可以叠加
  assert_eq(parsed("50%%"), Unary(Percent, Unary(Percent, NumberLit(50.0))))
  // 且它比乘法更紧
  assert_eq(
    parsed("2*50%"),
    Binary(Mul, NumberLit(2.0), Unary(Percent, NumberLit(50.0))),
  )
}

///|
test "concatenation binds looser than arithmetic" {
  assert_eq(
    parsed("1+2&3"),
    Binary(Concat, Binary(Add, NumberLit(1.0), NumberLit(2.0)), NumberLit(3.0)),
  )
}

///|
test "comparison binds loosest of all" {
  assert_eq(
    parsed("1+2>=3"),
    Binary(Ge, Binary(Add, NumberLit(1.0), NumberLit(2.0)), NumberLit(3.0)),
  )
}

///|
test "parses function calls, including nested and zero-argument ones" {
  assert_eq(
    parsed("SUM(A1,B2)"),
    Call("SUM", [
      Ref(@reference.CellRef::parse("A1").unwrap()),
      Ref(@reference.CellRef::parse("B2").unwrap()),
    ]),
  )
  // 零参数调用得到**空表**，而不是一个 Missing
  assert_eq(parsed("NOW()"), Call("NOW", []))
  assert_eq(
    parsed("SUM(MAX(A1,2),3)"),
    Call("SUM", [
      Call("MAX", [
        Ref(@reference.CellRef::parse("A1").unwrap()),
        NumberLit(2.0),
      ]),
      NumberLit(3.0),
    ]),
  )
}

///|
test "empty arguments become Missing, which is not the same as blank" {
  // `IF(A1,,2)` 中间那个位置是"调用方没提供参数"，
  // 与"A1 是空单元格"是两件事。
  assert_eq(
    parsed("IF(A1,,2)"),
    Call("IF", [
      Ref(@reference.CellRef::parse("A1").unwrap()),
      Missing,
      NumberLit(2.0),
    ]),
  )
  // 尾随空参数
  assert_eq(parsed("SUM(1,)"), Call("SUM", [NumberLit(1.0), Missing]))
  // 中段空参数
  assert_eq(
    parsed("SUM(1,,3)"),
    Call("SUM", [NumberLit(1.0), Missing, NumberLit(3.0)]),
  )
}

///|
test "parses ranges, including cross-sheet ones" {
  assert_eq(
    parsed("A1:B2"),
    Range(@reference.RangeRef::parse("A1:B2").unwrap()),
  )
  assert_eq(
    parsed("SUM(Sheet2!A1:B2)"),
    Call("SUM", [Range(@reference.RangeRef::parse("Sheet2!A1:B2").unwrap())]),
  )
}

// ================================================================ 语法错误

///|
test "reports syntax errors instead of producing a partial tree" {
  assert_true(parse("1+") is Err(_))
  assert_true(parse("(1+2") is Err(_))
  assert_true(parse("1+2)") is Err(_))
  assert_true(parse("SUM(1") is Err(_))
  // 两个表达式之间缺少运算符
  assert_true(parse("1 2") is Err(_))
  // 函数名后面必须有括号
  assert_true(parse("SUM") is Err(_))
  // 区域右边必须是引用
  assert_true(parse("A1:B") is Err(_))
  assert_true(parse("A1:5") is Err(_))
  // 空公式
  assert_true(parse("") is Err(_))
}

///|
test "errors carry a token position for diagnostics" {
  match parse("1+*2") {
    Err(ParseError(_, pos)) => assert_true(pos >= 0)
    Ok(_) => abort("1+*2 应该报错")
  }
}

// ================================================================ AST 辅助

///|
test "collect_refs deduplicates and expands ranges" {
  assert_eq(parsed("A1+A1+B2").collect_refs().length(), 2)
  // 区域展开成单个格子：依赖是"我引用了哪些格子"
  assert_eq(parsed("SUM(A1:B2)").collect_refs().length(), 4)
  assert_eq(parsed("A1+A1").collect_refs().length(), 1)
}

///|
test "collect_refs treats absolute and relative forms as one cell" {
  // 这是依赖图正确的前提：$A$1 与 A1 不能算两条边
  assert_eq(parsed("$A$1+A1").collect_refs().length(), 1)
  assert_eq(parsed("SUM($A$1:$B$2)").collect_refs().length(), 4)
}

///|
test "collect_refs keeps cross-sheet references separate" {
  assert_eq(parsed("A1+Sheet2!A1").collect_refs().length(), 2)
}

///|
test "collect_functions walks nested calls in first-seen order" {
  assert_eq(parsed("SUM(MAX(A1,2),3)").collect_functions(), ["SUM", "MAX"])
  assert_eq(parsed("SUM(SUM(1))").collect_functions(), ["SUM"])
  assert_eq(parsed("1+2").collect_functions(), [])
}

// ================================================================ 回显往返

///|
test "to_formula round-trips through the parser" {
  let formulas : Array[String] = [
    "1", "1+2", "1+2*3", "(1+2)*3", "-2^2", "2^3^2", "50%", "A1+B2", "$A$1+B2", "SUM(A1,B2)",
    "SUM(A1:B2)", "SUM(MAX(A1,2),3)", "Sheet2!A1+A1", "1+2&3", "A1>=B1", "\"a\"\"b\"",
    "TRUE", "#REF!",
  ]
  for f in formulas {
    let once = parsed(f).to_formula()
    let twice = parsed(once).to_formula()
    // 回显不保证与原文逐字符相同（括号会被规范化），但必须**幂等**。
    assert_eq(twice, once)
  }
}

///|
test "to_formula keeps parentheses where precedence would change meaning" {
  // (1+2)*3 不能回显成 1+2*3，那会改变语义
  assert_eq(parsed("(1+2)*3").to_formula(), "(1+2)*3")
  assert_eq(parsed("1+2*3").to_formula(), "1+2*3")
  // 括号多余时可以省略，语义不变
  assert_eq(parsed("(1)").to_formula(), "1")
}

///|
test "to_formula quotes and escapes text literals" {
  assert_eq(parsed("\"hi\"").to_formula(), "\"hi\"")
  assert_eq(parsed("\"a\"\"b\"").to_formula(), "\"a\"\"b\"")
}

// ================================================================ 单元格输入

///|
test "parse_cell_input splits formulas from literals" {
  match parse_cell_input("=1+2") {
    Ok(Formula(e)) => assert_eq(e, Binary(Add, NumberLit(1.0), NumberLit(2.0)))
    _ => abort("=1+2 应该是公式")
  }
  match parse_cell_input("hello") {
    Ok(Literal(v)) => assert_eq(v, @value.Text("hello"))
    _ => abort("hello 应该是文本字面量")
  }
  match parse_cell_input("123") {
    Ok(Literal(v)) => assert_eq(v, @value.Number(123.0))
    _ => abort("123 应该是数字字面量")
  }
  match parse_cell_input("TRUE") {
    Ok(Literal(v)) => assert_eq(v, @value.Bool(true))
    _ => abort("TRUE 应该是逻辑字面量")
  }
  match parse_cell_input("#REF!") {
    Ok(Literal(v)) => assert_eq(v, @value.Error(@value.Ref))
    _ => abort("#REF! 应该是错误值")
  }
  // 单独一个 '=' 不是公式（没有内容），当文本
  match parse_cell_input("=") {
    Ok(Literal(v)) => assert_eq(v, @value.Text("="))
    _ => abort("单独的 = 应该是文本")
  }
  // 空白 → 空单元格
  match parse_cell_input("   ") {
    Ok(Literal(v)) => assert_eq(v, @value.Blank)
    _ => abort("空白应该是 Blank")
  }
  // 公式语法错误要如实报错
  assert_true(parse_cell_input("=1+") is Err(_))
}

///|
test "literal_value tries number before text, and boolean before text" {
  // 顺序很重要：否则 "TRUE" 会变成普通文本
  assert_eq(literal_value("TRUE"), @value.Bool(true))
  assert_eq(literal_value(" true "), @value.Bool(true))
  assert_eq(literal_value("1e3"), @value.Number(1000.0))
  assert_eq(literal_value("abc"), @value.Text("abc"))
  assert_eq(literal_value(""), @value.Blank)
}
