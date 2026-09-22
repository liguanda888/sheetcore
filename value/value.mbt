///|
/// 单元格的值与计算错误，以及两者之间的转换规则。
///
/// 设计原则：**错误是值，不是异常。**
/// 电子表格里 `#DIV/0!` 会像普通值一样在依赖图里传播、被 `ISERROR` 检测、
/// 被比较。所以这里用 `Value::Error` 而不是抛异常 —— 抛异常一旦没接住，
/// 整张表就算不出来了，而这恰恰是电子表格最不该发生的事。

///|
/// 计算错误。变体对应电子表格里可见的错误字面量。
pub(all) enum CalcError {
  /// `#DIV/0!` 除以零
  DivByZero
  /// `#VALUE!` 类型不匹配（例如把 "abc" 当数字用）
  ValueType
  /// `#REF!` 引用了不存在的单元格或区域
  Ref
  /// `#NAME?` 未知函数名或未定义名称
  Name
  /// `#NUM!` 数值域错误（例如负数开平方）
  Num
  /// `#N/A` 查不到（VLOOKUP 未命中）
  NotAvailable
  /// `#CYCLE!` 循环引用
  Cycle
} derive(Debug, Eq)

///|
/// 错误的**字面量文本**（电子表格里显示的那一串）。
pub fn CalcError::literal(self : CalcError) -> String {
  match self {
    DivByZero => "#DIV/0!"
    ValueType => "#VALUE!"
    Ref => "#REF!"
    Name => "#NAME?"
    Num => "#NUM!"
    NotAvailable => "#N/A"
    Cycle => "#CYCLE!"
  }
}

///|
/// 从字面量文本还原错误（大小写不敏感）。
///
/// 用途：把外部数据（CSV、粘贴的文本）里写着 `#DIV/0!` 的单元格
/// 识别成错误值，而不是当成普通文本。
pub fn CalcError::from_literal(text : StringView) -> CalcError? {
  let t = text.trim().to_owned()
  let upper = ascii_upper(t)
  if upper == "#DIV/0!" {
    Some(DivByZero)
  } else if upper == "#VALUE!" {
    Some(ValueType)
  } else if upper == "#REF!" {
    Some(Ref)
  } else if upper == "#NAME?" {
    Some(Name)
  } else if upper == "#NUM!" {
    Some(Num)
  } else if upper == "#N/A" {
    Some(NotAvailable)
  } else if upper == "#CYCLE!" {
    Some(Cycle)
  } else {
    None
  }
}

///|
/// 错误是否可以**跨引用传播**。
///
/// 目前所有错误都传播 —— 这是电子表格的语义：`=A1+1` 在 A1 是 `#REF!` 时
/// 结果是 `#REF!`，而不是 1。留成函数是为了让将来可能出现的例外
/// （例如某些统计函数会忽略错误）有一个明确的落点。
pub fn CalcError::propagates(self : CalcError) -> Bool {
  match self {
    _ => true
  }
}

///|
/// 单元格的值。
pub(all) enum Value {
  /// 空单元格。**不等于 0，也不等于 ""** —— 它的行为取决于上下文：
  /// 参与算术时当 0，参与文本拼接时当 ""，参与计数时**不计入**。
  Blank
  Number(Double)
  Text(String)
  Bool(Bool)
  Error(CalcError)
} derive(Debug, Eq)

///|
/// 构造数字值。
pub fn num(n : Double) -> Value {
  Number(n)
}

///|
/// 构造文本值。
pub fn text(s : StringView) -> Value {
  Text(s.to_owned())
}

///|
/// 构造布尔值。
pub fn boolean(b : Bool) -> Value {
  Bool(b)
}

///|
/// 构造错误值。
pub fn err(e : CalcError) -> Value {
  Error(e)
}

///|
/// 是否是错误值。
pub fn Value::is_error(self : Value) -> Bool {
  match self {
    Error(_) => true
    _ => false
  }
}

///|
/// 是否是空值。
pub fn Value::is_blank(self : Value) -> Bool {
  match self {
    Blank => true
    _ => false
  }
}

///|
/// 是否是数字。
pub fn Value::is_number(self : Value) -> Bool {
  match self {
    Number(_) => true
    _ => false
  }
}

///|
/// 转成数字，遵守电子表格的隐式转换规则：
///
/// | 输入 | 结果 |
/// |---|---|
/// | `Number(n)` | `n` |
/// | `Blank` | `0` |
/// | `Bool(true/false)` | `1` / `0` |
/// | `Text("12.5")` | `12.5` |
/// | `Text("abc")` | `#VALUE!` |
/// | `Error(e)` | **原样传播 `e`** |
pub fn Value::as_number(self : Value) -> Result[Double, CalcError] {
  match self {
    Number(n) => Ok(n)
    Blank => Ok(0.0)
    Bool(b) => Ok(if b { 1.0 } else { 0.0 })
    Error(e) => Err(e)
    Text(s) =>
      match parse_number(s) {
        Some(n) => Ok(n)
        None => Err(ValueType)
      }
  }
}

///|
/// 转成文本。
///
/// 与 `as_number` 不同，这里**不会失败** —— 任何值都有一个文本形式
/// （错误值转成它的字面量）。数字的格式化规则见 `format_number`。
pub fn Value::as_text(self : Value) -> String {
  match self {
    Text(s) => s
    Blank => ""
    Number(n) => format_number(n)
    Bool(b) => if b { "TRUE" } else { "FALSE" }
    Error(e) => e.literal()
  }
}

///|
/// 转成布尔值。
///
/// | 输入 | 结果 |
/// |---|---|
/// | `Bool(b)` | `b` |
/// | `Number(n)` | `n != 0` |
/// | `Blank` | `false` |
/// | `Text("true"/"TRUE")` | `true`（大小写不敏感） |
/// | `Text(其它)` | `#VALUE!` |
/// | `Error(e)` | 原样传播 |
pub fn Value::as_bool(self : Value) -> Result[Bool, CalcError] {
  match self {
    Bool(b) => Ok(b)
    Number(n) => Ok(n != 0.0)
    Blank => Ok(false)
    Error(e) => Err(e)
    Text(s) => {
      let upper = ascii_upper(s.trim().to_owned())
      if upper == "TRUE" {
        Ok(true)
      } else if upper == "FALSE" {
        Ok(false)
      } else {
        Err(ValueType)
      }
    }
  }
}

///|
/// 显示形式 —— 给 CLI 和调试用。与 `as_text` 的唯一区别是空值显示为空串之外，
/// 这里保持同样的语义，单独留一个名字是为了让"给机器看"与"给人看"
/// 将来可以分开演进（例如数字的千分位、日期格式）。
pub fn Value::display(self : Value) -> String {
  self.as_text()
}

///|
/// 跨类型比较时的**排序档次**，复刻电子表格的排序规则：
/// 数字 < 文本 < 逻辑值 < 错误值。
///
/// 为什么需要它：`=SORT({1,"a",TRUE})` 这类操作要求跨类型可比，
/// 而电子表格选择的是"按类型分档、档内再比"，不是报错。
pub fn Value::rank(self : Value) -> Int {
  match self {
    Blank => 0
    Number(_) => 1
    Text(_) => 2
    Bool(_) => 3
    Error(_) => 4
  }
}

///|
/// 比较两个值，返回 `<0` / `0` / `>`0。
///
/// 规则：
/// - 类型档次不同 → 按 `rank` 比较
/// - 同为数字 → 数值比较
/// - 同为文本 → 逐字符按码位比较（**不做** locale 排序，保证可复现）
/// - 同为逻辑值 → `false` < `true`
/// - 空值与数字比 → 空值当 0；空值与文本比 → 空值当 ""
/// - 同为错误 → 按字面量比较（让排序有确定结果，而不是报错）
pub fn compare(a : Value, b : Value) -> Int {
  // 空值先按对方类型归位，再走正常比较。
  let left = match (a, b) {
    (Blank, Number(_)) => Number(0.0)
    (Blank, Text(_)) => Text("")
    (Blank, Bool(_)) => Bool(false)
    _ => a
  }
  let right = match (a, b) {
    (Number(_), Blank) => Number(0.0)
    (Text(_), Blank) => Text("")
    (Bool(_), Blank) => Bool(false)
    _ => b
  }
  let ra = left.rank()
  let rb = right.rank()
  if ra != rb {
    return ra - rb
  }
  match (left, right) {
    (Number(x), Number(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Text(x), Text(y)) => compare_strings(x, y)
    (Bool(x), Bool(y)) => if x == y { 0 } else if x { 1 } else { -1 }
    (Error(x), Error(y)) => compare_strings(x.literal(), y.literal())
    _ => 0
  }
}

///|
/// 两个值是否相等（同类型同值；空值与空值相等）。
pub fn value_eq(a : Value, b : Value) -> Bool {
  a == b
}

///|
/// 数字 → 文本。
///
/// 规则（刻意贴近电子表格的观感）：
/// - 整数值不带小数点：`1` 而不是 `1.0`
/// - `-0` 归一成 `0`（否则 `=-0` 会显示成 `-0`，很怪）
/// - 非有限值给出电子表格的错误字面量语义：`NaN` → `#NUM!`、`±Inf` → `#DIV/0!`
///   （在电子表格里这两者本就该是错误，而不是一个可打印的数字）
pub fn format_number(n : Double) -> String {
  if n.is_nan() {
    return "#NUM!"
  }
  if n.is_inf() {
    return "#DIV/0!"
  }
  let normalized = if n == 0.0 { 0.0 } else { n }
  if is_integral(normalized) && abs_double(normalized) < 1.0e15 {
    return int_to_string(normalized.to_int())
  }
  normalized.to_string()
}

///|
/// 是否是整数值。
pub fn is_integral(n : Double) -> Bool {
  n == trunc_double(n)
}

///|
/// 取绝对值（避免依赖具体版本里 `Double::abs` 的名字差异）。
pub fn abs_double(n : Double) -> Double {
  if n < 0.0 {
    -n
  } else {
    n
  }
}

///|
/// 向零取整。
pub fn trunc_double(n : Double) -> Double {
  n.to_int().to_double()
}

///|
/// 32 位整数 → 十进制文本。
///
/// 自己实现是为了**不依赖任何版本相关的数字格式化行为** ——
/// `Int::to_string` 存在，但显式实现让 `format_number` 的行为完全可控、可测。
pub fn int_to_string(n : Int) -> String {
  if n == 0 {
    return "0"
  }
  let negative = n < 0
  // 用负累加避免 `-Int::min_value` 溢出。
  let buf = StringBuilder::StringBuilder()
  let mut value = if negative { n } else { -n }
  while value <= -10 {
    let digit = -(value % 10)
    buf.write_char(digit_char(digit))
    value = value / 10
  }
  buf.write_char(digit_char(-value))
  if negative {
    buf.write_char('-')
  }
  // 上面是从低位往高位写，需要反转。
  reverse_string(buf.to_string())
}

///|
/// 0..9 → 字符。
fn digit_char(d : Int) -> Char {
  let digits : Array[Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']
  digits[d]
}

///|
/// 反转字符串（逐字符，天然对齐字符边界）。
fn reverse_string(s : StringView) -> String {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let buf = StringBuilder::StringBuilder()
  let mut i = chars.length() - 1
  while i >= 0 {
    buf.write_char(chars[i])
    i = i - 1
  }
  buf.to_string()
}

///|
/// 把一段文本解析成数字；不是**纯数字**就返回 `None`。
///
/// 接受的文法：
///   `空白? 符号? 数字* ('.' 数字*)? ([eE] 符号? 数字+)? 空白?`
/// 且尾数部分至少有一位数字、末尾不能有多余字符。
///
/// **刻意比 Excel 严格**：Excel 会把 `"12abc"` 当成 12、把 `"$1,200"` 当成 1200，
/// 那套规则难以预测、也难以测试。这里只接受纯粹的十进制表示，
/// 其余一律 `#VALUE!`。差异写在 README 的「与 Excel 的已知差异」一节。
pub fn parse_number(text : StringView) -> Double? {
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  let n = chars.length()
  let mut start = 0
  while start < n && is_space(chars[start]) {
    start = start + 1
  }
  let mut end = n
  while end > start && is_space(chars[end - 1]) {
    end = end - 1
  }
  if start >= end {
    return None
  }
  let mut i = start
  let mut negative = false
  if chars[i] == '+' || chars[i] == '-' {
    negative = chars[i] == '-'
    i = i + 1
  }
  let mut mantissa = 0.0
  let mut digits = 0
  while i < end && is_digit(chars[i]) {
    mantissa = mantissa * 10.0 + digit_value(chars[i])
    digits = digits + 1
    i = i + 1
  }
  if i < end && chars[i] == '.' {
    i = i + 1
    let mut scale = 0.1
    while i < end && is_digit(chars[i]) {
      mantissa = mantissa + digit_value(chars[i]) * scale
      scale = scale / 10.0
      digits = digits + 1
      i = i + 1
    }
  }
  if digits == 0 {
    return None
  }
  let mut exponent = 0
  if i < end && (chars[i] == 'e' || chars[i] == 'E') {
    i = i + 1
    let mut exp_negative = false
    if i < end && (chars[i] == '+' || chars[i] == '-') {
      exp_negative = chars[i] == '-'
      i = i + 1
    }
    let mut exp_digits = 0
    while i < end && is_digit(chars[i]) {
      exponent = exponent * 10 + digit_value(chars[i]).to_int()
      exp_digits = exp_digits + 1
      i = i + 1
    }
    if exp_digits == 0 {
      return None
    }
    if exp_negative {
      exponent = -exponent
    }
  }
  if i != end {
    return None
  }
  let mut result = if negative { -mantissa } else { mantissa }
  let magnitude = if exponent < 0 { -exponent } else { exponent }
  let mut k = 0
  while k < magnitude {
    result = if exponent < 0 { result / 10.0 } else { result * 10.0 }
    k = k + 1
  }
  Some(result)
}

///|
fn is_space(ch : Char) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

///|
fn is_digit(ch : Char) -> Bool {
  ch >= '0' && ch <= '9'
}

///|
fn digit_value(ch : Char) -> Double {
  (ch.to_int() - '0'.to_int()).to_double()
}

///|
/// ASCII 大写化（只处理 ASCII；中文无大小写，原样保留）。
pub fn ascii_upper(s : StringView) -> String {
  let buf = StringBuilder::StringBuilder()
  for ch in s {
    if ch >= 'a' && ch <= 'z' {
      let offset = ch.to_int() - 'a'.to_int()
      buf.write_char(upper_letter(offset))
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// 0..25 → 'A'..'Z'（查表，避免整数→字符的转换 API）。
fn upper_letter(offset : Int) -> Char {
  let table : Array[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ]
  table[offset]
}

///|
/// 逐字符比较两个字符串（按码位，不做 locale 排序）。
pub fn compare_strings(a : StringView, b : StringView) -> Int {
  let ca : Array[Char] = []
  let cb : Array[Char] = []
  for ch in a {
    ca.push(ch)
  }
  for ch in b {
    cb.push(ch)
  }
  let mut i = 0
  let n = if ca.length() < cb.length() { ca.length() } else { cb.length() }
  while i < n {
    let x = ca[i].to_int()
    let y = cb[i].to_int()
    if x != y {
      return x - y
    }
    i = i + 1
  }
  ca.length() - cb.length()
}
