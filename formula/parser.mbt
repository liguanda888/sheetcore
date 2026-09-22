///|
/// 公式的语法分析（递归下降 + 优先级爬升）。
///
/// 优先级从低到高（与电子表格一致）：
///
/// ```
/// 1  比较      =  <>  <  <=  >  >=
/// 2  拼接      &
/// 3  加减      +  -
/// 4  乘除      *  /
/// 5  一元      -x   +x          ← 注意：一元比幂**更紧**，见下
/// 6  后缀      x%
/// 7  幂        ^   （右结合）
/// ```
///
/// **一元负号比幂更紧**，所以 `-2^2` = `(-2)^2` = 4，而不是 -4。
/// 这与大多数编程语言相反，但正是电子表格的行为 —— 本项目声明的是
/// 电子表格语义，所以跟随它，并用单元测试把这个"反直觉"钉住。

///|
/// 语法错误。第二个参数是**词法单元下标**（不是字符下标）——
/// 报错时更方便指着"第几个 token"，字符位置由词法层给。
pub suberror ParseError {
  ParseError(String, Int)
}

///|
/// 解析上下文。`pos` 可变，逐个消费词法单元。
priv struct Cursor {
  tokens : Array[Token]
  mut pos : Int
}

///|
/// 把公式文本解析成 AST（**不含前导 `=`**）。
///
/// 词法错误与语法错误都从这里以 `ParseError` 返回，不抛出。
pub fn parse(src : StringView) -> Result[Expr, ParseError] {
  let tokens = match tokenize(src) {
    Ok(t) => t
    Err(e) => return Err(ParseError(e.message, e.position))
  }
  let cursor : Cursor = { tokens, pos: 0, }
  let expr = try {
    let e = cursor.parse_comparison()
    match cursor.peek() {
      Eof => e
      other =>
        raise ParseError(
          "Unexpected token after the expression: " + token_text(other),
          cursor.pos,
        )
    }
  } catch {
    e => return Err(e)
  }
  Ok(expr)
}

///|
/// 解析**单元格内容**：以 `=` 开头当公式，否则当字面量。
///
/// 这是"用户输入 → AST"的统一入口：`=1+2` 是公式，`'=1+2` 或 `hello` 是文本。
/// 前导 `=` 后紧跟内容才算公式；单独的 `=` 视为文本。
pub fn parse_cell_input(src : StringView) -> Result[CellInput, ParseError] {
  let trimmed = src.trim()
  if trimmed.length() > 1 && trimmed[0] == '=' {
    // 去掉前导 '='，注意要按字符而不是字节切
    let chars : Array[Char] = []
    for ch in trimmed {
      chars.push(ch)
    }
    let buf = StringBuilder::StringBuilder()
    let mut i = 1
    while i < chars.length() {
      buf.write_char(chars[i])
      i = i + 1
    }
    match parse(buf.to_string()) {
      Ok(e) => Ok(Formula(e))
      Err(err) => Err(err)
    }
  } else {
    // 不是公式：按字面量解析（数字 / 逻辑值 / 错误字面量 / 文本）
    Ok(Literal(literal_value(trimmed)))
  }
}

///|
/// 单元格内容的两种形态。
pub(all) enum CellInput {
  Formula(Expr)
  Literal(@value.Value)
}

///|
/// 把一段非公式文本转成字面量值。
///
/// 判定顺序很重要：先试数字、再试逻辑值与错误字面量，最后才落到文本。
/// 否则 `"TRUE"` 会被当成普通文本而不是逻辑值。
pub fn literal_value(text : StringView) -> @value.Value {
  let trimmed = text.trim()
  if trimmed.length() == 0 {
    return @value.Blank
  }
  match @value.CalcError::from_literal(trimmed) {
    Some(e) => return @value.Error(e)
    None => ()
  }
  let upper = @value.ascii_upper(trimmed)
  if upper == "TRUE" {
    return @value.Bool(true)
  }
  if upper == "FALSE" {
    return @value.Bool(false)
  }
  match @value.parse_number(trimmed) {
    Some(d) => @value.Number(d)
    None => @value.Text(trimmed.to_owned())
  }
}

// ---------------------------------------------------------------- Cursor 原语

///|
fn Cursor::peek(self : Cursor) -> Token {
  if self.pos < self.tokens.length() {
    self.tokens[self.pos]
  } else {
    Eof
  }
}

///|
/// 消费一个词法单元。**返回 `Unit`** —— 需要值的地方先 `peek()`，
/// 这样调用处不必到处写 `ignore(...)`。
fn Cursor::advance(self : Cursor) -> Unit {
  if self.pos < self.tokens.length() {
    self.pos = self.pos + 1
  }
}

///|
fn Cursor::eat(self : Cursor, t : Token) -> Bool {
  if self.peek() == t {
    self.advance()
    true
  } else {
    false
  }
}

// ---------------------------------------------------------------- 优先级层次

///|
/// 比较层（最低优先级）。
fn Cursor::parse_comparison(self : Cursor) -> Expr raise ParseError {
  let mut left = self.parse_concat()
  while true {
    let op = match self.peek() {
      EqOp => Eq
      NeOp => Ne
      LtOp => Lt
      LeOp => Le
      GtOp => Gt
      GeOp => Ge
      _ => break
    }
    self.advance()
    let right = self.parse_concat()
    left = Binary(op, left, right)
  }
  left
}

///|
fn Cursor::parse_concat(self : Cursor) -> Expr raise ParseError {
  let mut left = self.parse_additive()
  while self.peek() == Amp {
    self.advance()
    let right = self.parse_additive()
    left = Binary(Concat, left, right)
  }
  left
}

///|
fn Cursor::parse_additive(self : Cursor) -> Expr raise ParseError {
  let mut left = self.parse_multiplicative()
  while true {
    let op = match self.peek() {
      Plus => Add
      Minus => Sub
      _ => break
    }
    self.advance()
    let right = self.parse_multiplicative()
    left = Binary(op, left, right)
  }
  left
}

///|
fn Cursor::parse_multiplicative(self : Cursor) -> Expr raise ParseError {
  let mut left = self.parse_power()
  while true {
    let op = match self.peek() {
      Star => Mul
      Slash => Div
      _ => break
    }
    self.advance()
    let right = self.parse_power()
    left = Binary(op, left, right)
  }
  left
}

///|
/// 幂层，**右结合**：`2^3^2` = `2^(3^2)` = 512。
///
/// 它调用 `parse_unary` 而不是反过来 —— 这正是"一元负号比幂更紧"的实现方式。
/// 调用顺序决定了语义：写成 `unary -> power` 就会得到 `-(2^2) = -4`，
/// 而电子表格要的是 `(-2)^2 = 4`。
fn Cursor::parse_power(self : Cursor) -> Expr raise ParseError {
  let base = self.parse_unary()
  if self.peek() == Caret {
    self.advance()
    // 右结合：递归回幂层自己
    let exponent = self.parse_power()
    Binary(Pow, base, exponent)
  } else {
    base
  }
}

///|
/// 一元层。
fn Cursor::parse_unary(self : Cursor) -> Expr raise ParseError {
  match self.peek() {
    Minus => {
      self.advance()
      Unary(Neg, self.parse_unary())
    }
    Plus => {
      self.advance()
      Unary(Pos, self.parse_unary())
    }
    _ => self.parse_postfix()
  }
}

///|
/// 后缀层：`50%`。
fn Cursor::parse_postfix(self : Cursor) -> Expr raise ParseError {
  let mut e = self.parse_primary()
  while self.peek() == Percent {
    self.advance()
    e = Unary(Percent, e)
  }
  e
}

///|
fn Cursor::parse_primary(self : Cursor) -> Expr raise ParseError {
  let t = self.peek()
  match t {
    Number(d) => {
      self.advance()
      NumberLit(d)
    }
    Str(s) => {
      self.advance()
      TextLit(s)
    }
    BoolLit(b) => {
      self.advance()
      BoolLit(b)
    }
    ErrorLit(e) => {
      self.advance()
      ErrorLit(e)
    }
    Ref(r) => {
      self.advance()
      // 后面跟 ':' 就是区域
      if self.peek() == Colon {
        self.advance()
        match self.peek() {
          Ref(r2) => {
            self.advance()
            match @reference.range_from(r, r2) {
              Some(range) => Range(range)
              None =>
                raise ParseError(
                  "The two corners of a range must be on the same sheet",
                  self.pos,
                )
            }
          }
          other =>
            raise ParseError(
              "Expected a cell reference after ':' but found " +
              token_text(other),
              self.pos,
            )
        }
      } else {
        Ref(r)
      }
    }
    LParen => {
      self.advance()
      let inner = self.parse_comparison()
      if !self.eat(RParen) {
        raise ParseError("Expected ')' to close the group", self.pos)
      }
      inner
    }
    Ident(name) => {
      self.advance()
      if !self.eat(LParen) {
        raise ParseError("Expected '(' after the name '" + name + "'", self.pos)
      }
      let args = self.parse_args()
      if !self.eat(RParen) {
        raise ParseError("Expected ')' to close the argument list", self.pos)
      }
      Call(name, args)
    }
    other =>
      raise ParseError("Unexpected token: " + token_text(other), self.pos)
  }
}

///|
/// 解析函数实参表。`(` 已被吃掉，停在 `)` 上（**不消费** `)`）。
///
/// 空实参 `Missing` 与"空单元格"不是一回事：
/// `IF(A1,,2)` 里那个空位置是"调用方没提供"，而 `A1` 是"提供了但值为空"。
/// 函数需要区别对待（例如 `COUNT` 会忽略 `Missing`）。
fn Cursor::parse_args(self : Cursor) -> Array[Expr] raise ParseError {
  let args : Array[Expr] = []
  // 零参数调用 `NOW()` —— 立刻返回空表，而不是一个 Missing
  if self.peek() == RParen {
    return args
  }
  while true {
    if self.peek() == Comma || self.peek() == RParen {
      args.push(Missing)
    } else {
      args.push(self.parse_comparison())
    }
    match self.peek() {
      Comma => self.advance()
      RParen => break
      other =>
        raise ParseError(
          "Expected ',' or ')' in the argument list but found " +
          token_text(other),
          self.pos,
        )
    }
  }
  args
}
