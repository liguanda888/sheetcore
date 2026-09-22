///|
/// 公式的词法分析。
///
/// 最容易出错的地方是**歧义消解**：同一串字母数字既可能是单元格引用，
/// 也可能是函数名。规则如下：
///
/// | 输入 | 判定 | 依据 |
/// |---|---|---|
/// | `A1` | 单元格引用 | 能按 A1 记法解析 |
/// | `Sheet2!A1` | 单元格引用 | 同上（带表名） |
/// | `LOG10(2)` | 函数名 + 参数 | 后面紧跟 `(` —— 这是唯一的判据 |
/// | `TRUE` | 逻辑字面量 | 保留字，大小写不敏感 |
/// | `FOO` | 名字（求值时报 `#NAME?`） | 兜底 |
///
/// `LOG10` 是关键用例：它形如引用却不是引用。判据只能是**后面跟不跟 `(`**。

///|
/// 词法单元。
pub(all) enum Token {
  Number(Double)
  Str(String)
  /// 函数名或未识别的名字（已大写化）
  Ident(String)
  BoolLit(Bool)
  /// 公式里写死的错误值，例如 `=#N/A`
  ErrorLit(@value.CalcError)
  Ref(@reference.CellRef)
  Plus
  Minus
  Star
  Slash
  Caret
  Amp
  EqOp
  NeOp
  LtOp
  LeOp
  GtOp
  GeOp
  LParen
  RParen
  Comma
  Colon
  Percent
  Eof
} derive(Debug, Eq)

///|
/// 词法错误，带出错位置（**字符下标**，从 0 开始）。
pub(all) struct LexError {
  message : String
  position : Int
} derive(Debug, Eq)

///|
/// 把公式文本切成词法单元（**不含前导 `=`**）。
pub fn tokenize(src : StringView) -> Result[Array[Token], LexError] {
  let chars : Array[Char] = []
  for ch in src {
    chars.push(ch)
  }
  let n = chars.length()
  let out : Array[Token] = []
  let mut i = 0
  while i < n {
    let ch = chars[i]
    if is_space(ch) {
      i = i + 1
      continue
    }
    // ---- 字符串字面量 ----
    if ch == '"' {
      let buf = StringBuilder::StringBuilder()
      i = i + 1
      let mut closed = false
      while i < n {
        if chars[i] == '"' {
          if i + 1 < n && chars[i + 1] == '"' {
            // "" 表示一个真正的引号
            buf.write_char('"')
            i = i + 2
          } else {
            i = i + 1
            closed = true
            break
          }
        } else {
          buf.write_char(chars[i])
          i = i + 1
        }
      }
      if !closed {
        return Err({ message: "Unterminated string literal", position: i, })
      }
      out.push(Str(buf.to_string()))
      continue
    }
    // ---- 错误字面量（#DIV/0! 等）----
    if ch == '#' {
      let start = i
      i = i + 1
      while i < n && is_error_literal_char(chars[i]) {
        i = i + 1
      }
      let literal = slice(chars, start, i)
      match @value.CalcError::from_literal(literal) {
        Some(e) => out.push(ErrorLit(e))
        None =>
          return Err({
            message: "Unknown error literal: " + literal,
            position: start,
          })
      }
      continue
    }
    // ---- 数字字面量 ----
    if is_digit(ch) || (ch == '.' && i + 1 < n && is_digit(chars[i + 1])) {
      let start = i
      while i < n && is_digit(chars[i]) {
        i = i + 1
      }
      if i < n && chars[i] == '.' {
        i = i + 1
        while i < n && is_digit(chars[i]) {
          i = i + 1
        }
      }
      // 指数部分要**看一位再决定**：`2E` 应当被切成年 2 与名字 E，
      // 而不是一个残缺的指数。所以先试探，成立才吞掉。
      if i < n && (chars[i] == 'e' || chars[i] == 'E') {
        let mut probe = i + 1
        if probe < n && (chars[probe] == '+' || chars[probe] == '-') {
          probe = probe + 1
        }
        if probe < n && is_digit(chars[probe]) {
          while probe < n && is_digit(chars[probe]) {
            probe = probe + 1
          }
          i = probe
        }
      }
      let literal = slice(chars, start, i)
      match @value.parse_number(literal) {
        Some(d) => out.push(Number(d))
        None =>
          return Err({ message: "Invalid number: " + literal, position: start, })
      }
      continue
    }
    // ---- 单元格引用 / 名字 ----
    if ch == '$' || ch == '\'' || is_letter(ch) {
      // 先按"可能是引用"取最长候选串：一直吃到分隔符为止。
      // 注意**空格不算分隔符** —— 否则 `'My Sheet'!A1` 会被切断。
      let mut run_end = i
      while run_end < n && !is_delimiter(chars[run_end]) {
        run_end = run_end + 1
      }
      let candidate = trim_owned(slice(chars, i, run_end))
      // 关键判据：**后面紧跟 `(` 就是函数调用，不是单元格引用**。
      //
      // 这条规则不能省。`LOG10` 是一个完全合法的 A1 记法 —— 列 "LOG"、
      // 第 10 行 —— 所以只靠 "能不能解析成引用" 无法区分 `LOG10(2)` 与 `A1`。
      // 少了这一步，`LOG10(2)` 会被切成 `Ref(LOG10)` 加一个孤立的括号。
      let called = run_end < n && chars[run_end] == '('
      if !called {
        match @reference.CellRef::parse(candidate) {
          Some(r) => {
            out.push(Ref(r))
            i = run_end
            continue
          }
          None => ()
        }
      }
      // 退化成名字
      let ident_start = i
      while i < n &&
            (is_letter(chars[i]) || is_digit(chars[i]) || chars[i] == '_') {
        i = i + 1
      }
      if i == ident_start {
        return Err({
          message: "Unexpected character: " + char_text(ch),
          position: i,
        })
      }
      let name = slice(chars, ident_start, i)
      let upper = @value.ascii_upper(name)
      if upper == "TRUE" {
        out.push(BoolLit(true))
      } else if upper == "FALSE" {
        out.push(BoolLit(false))
      } else {
        out.push(Ident(upper))
      }
      continue
    }
    // ---- 运算符与标点 ----
    match ch {
      '+' => {
        out.push(Plus)
        i = i + 1
      }
      '-' => {
        out.push(Minus)
        i = i + 1
      }
      '*' => {
        out.push(Star)
        i = i + 1
      }
      '/' => {
        out.push(Slash)
        i = i + 1
      }
      '^' => {
        out.push(Caret)
        i = i + 1
      }
      '&' => {
        out.push(Amp)
        i = i + 1
      }
      '%' => {
        out.push(Percent)
        i = i + 1
      }
      '(' => {
        out.push(LParen)
        i = i + 1
      }
      ')' => {
        out.push(RParen)
        i = i + 1
      }
      ',' => {
        out.push(Comma)
        i = i + 1
      }
      // 冒号既是区域分隔符，也是表名分隔符。表名已被上面的引用分支吃掉，
      // 所以走到这里的 ':' 一定是区域分隔符。
      ':' => {
        out.push(Colon)
        i = i + 1
      }
      '=' => {
        out.push(EqOp)
        i = i + 1
      }
      '<' =>
        if i + 1 < n && chars[i + 1] == '>' {
          out.push(NeOp)
          i = i + 2
        } else if i + 1 < n && chars[i + 1] == '=' {
          out.push(LeOp)
          i = i + 2
        } else {
          out.push(LtOp)
          i = i + 1
        }
      '>' =>
        if i + 1 < n && chars[i + 1] == '=' {
          out.push(GeOp)
          i = i + 2
        } else {
          out.push(GtOp)
          i = i + 1
        }
      _ =>
        return Err({
          message: "Unexpected character: " + char_text(ch),
          position: i,
        })
    }
  }
  out.push(Eof)
  Ok(out)
}

///|
/// 词法单元的**显示形式**，用于报错信息。
pub fn token_text(t : Token) -> String {
  match t {
    Number(d) => @value.format_number(d)
    Str(s) => quote_formula_string(s)
    Ident(name) => name
    BoolLit(b) => if b { "TRUE" } else { "FALSE" }
    ErrorLit(e) => e.literal()
    Ref(r) => r.to_text()
    Plus => "+"
    Minus => "-"
    Star => "*"
    Slash => "/"
    Caret => "^"
    Amp => "&"
    EqOp => "="
    NeOp => "<>"
    LtOp => "<"
    LeOp => "<="
    GtOp => ">"
    GeOp => ">="
    LParen => "("
    RParen => ")"
    Comma => ","
    Colon => ":"
    Percent => "%"
    Eof => "<end of formula>"
  }
}

///|
/// 是否是**引用候选串的终止符**。
///
/// 刻意**不含空格**：`'My Sheet'!A1` 里的空格属于表名，切开就解析不了。
/// 代价是 `A1 + B1` 的候选串会带上尾随空格 —— 用 `trim` 消化掉即可。
fn is_delimiter(ch : Char) -> Bool {
  match ch {
    '('
    | ')'
    | ','
    | '+'
    | '-'
    | '*'
    | '/'
    | '^'
    | '&'
    | '='
    | '<'
    | '>'
    | '%'
    | ':'
    | '"'
    | '#' => true
    _ => false
  }
}

///|
fn is_error_literal_char(ch : Char) -> Bool {
  is_letter(ch) || is_digit(ch) || ch == '/' || ch == '?' || ch == '!'
}

///|
fn is_letter(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

///|
fn is_digit(ch : Char) -> Bool {
  ch >= '0' && ch <= '9'
}

///|
fn is_space(ch : Char) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

///|
fn slice(chars : Array[Char], from : Int, to : Int) -> String {
  let buf = StringBuilder::StringBuilder()
  let mut i = from
  while i < to {
    buf.write_char(chars[i])
    i = i + 1
  }
  buf.to_string()
}

///|
fn trim_owned(s : StringView) -> String {
  s.trim().to_owned()
}

///|
fn char_text(ch : Char) -> String {
  let buf = StringBuilder::StringBuilder()
  buf.write_char(ch)
  buf.to_string()
}
