///|
/// 内置函数库。
///
/// 函数实参分两种形态，这个区分**不是形式主义** —— 它对应电子表格里
/// 一条真实且容易忽略的规则：
///
/// | 形态 | 来源 | 聚合函数如何处理 |
/// |---|---|---|
/// | `Scalar` | `SUM(1, "2")` 里的直接实参 | **强制转换**：`"2"` → 2，`"abc"` → `#VALUE!` |
/// | `List` | `SUM(A1:A3)` 里区域展开出的值 | **忽略**其中的文本与空单元格 |
///
/// 所以 `SUM("abc")` 是 `#VALUE!`，而 `SUM(A1:A3)` 在 A1 是 "abc" 时只是跳过它。
/// 合并成一种形态就表达不了这个差异。

///|
/// 函数实参。
///
/// `Scalar` 与 `Cell` 都是"单个值"，但**来源不同、聚合规则也不同** ——
/// 这个区分复刻了电子表格里一条真实且容易忽略的规则：
///
/// | 形态 | 来源 | 聚合函数如何处理 |
/// |---|---|---|
/// | `Scalar` | 写在公式里的字面量实参 | **强制转换**：`SUM("2")` → 2，`SUM("abc")` → `#VALUE!` |
/// | `Cell` | 引用求值的结果（单个格子） | **忽略**文本与空值：A1 是 "abc" 时 `SUM(A1)` → 0 |
/// | `List` | 区域展开出的一组值 | **忽略**其中的文本与空值 |
///
/// 合并 `Scalar` 与 `Cell` 会让 `SUM(A1)`（A1 为文本）错误地报 `#VALUE!`，
/// 而 Excel 返回 0 —— 这一点由单元测试发现。
pub(all) enum Arg {
  Scalar(@value.Value)
  Cell(@value.Value)
  List(Array[@value.Value])
} derive(Debug)

///|
/// 调用一个内置函数。名字**必须已大写**（词法层已做）。
/// 未知函数返回 `#NAME?`。
pub fn call(name : StringView, args : Array[Arg]) -> @value.Value {
  match name {
    // ---- 聚合 ----
    "SUM" => aggregate(args, AggKind::Sum)
    "PRODUCT" => aggregate(args, AggKind::Product)
    "AVERAGE" => aggregate(args, AggKind::Average)
    "MIN" => aggregate(args, AggKind::Min)
    "MAX" => aggregate(args, AggKind::Max)
    "MEDIAN" => aggregate(args, AggKind::Median)
    "COUNT" => count_numbers(args)
    "COUNTA" => count_nonblank(args)
    "COUNTBLANK" => count_blank(args)
    // ---- 数学 ----
    "ABS" => unary_number(args, AbsFn)
    "INT" => unary_number(args, IntFn)
    "SIGN" => unary_number(args, SignFn)
    "SQRT" => unary_number(args, SqrtFn)
    "POWER" => binary_number(args, PowFn)
    "MOD" => binary_number(args, ModFn)
    "ROUND" => round_fn(args)
    // ---- 逻辑 ----
    "AND" => logical_all(args, true)
    "OR" => logical_any(args, true)
    "NOT" => logical_not(args)
    "ISERROR" => is_kind(args, IsErrorKind)
    "ISBLANK" => is_kind(args, IsBlankKind)
    "ISNUMBER" => is_kind(args, IsNumberKind)
    "ISTEXT" => is_kind(args, IsTextKind)
    "ISLOGICAL" => is_kind(args, IsLogicalKind)
    "ISNA" => is_na(args)
    // ---- 文本 ----
    "LEN" => text_len(args)
    "UPPER" => text_map(args, UpperFn)
    "LOWER" => text_map(args, LowerFn)
    "TRIM" => text_map(args, TrimFn)
    "CONCAT" => text_concat(args)
    _ => @value.Error(@value.Name)
  }
}

///|
/// 已知函数名列表（供文档与错误提示使用）。
pub let known_functions : Array[String] = [
  "SUM", "PRODUCT", "AVERAGE", "MIN", "MAX", "MEDIAN", "COUNT", "COUNTA", "COUNTBLANK",
  "ABS", "INT", "SIGN", "SQRT", "POWER", "MOD", "ROUND", "AND", "OR", "NOT", "ISERROR",
  "ISBLANK", "ISNUMBER", "ISTEXT", "ISLOGICAL", "ISNA", "LEN", "UPPER", "LOWER",
  "TRIM", "CONCAT",
]

///|
/// 由引擎特殊处理的函数（**惰性求值**，不能按普通函数先算完实参再调用）。
///
/// `IF(A1=0, 0, 1/A1)` 在 A1=0 时必须不计算 `1/A1`，否则会凭空产生
/// `#DIV/0!`。所以 IF / IFERROR 的判断与分支选择必须由引擎做。
pub let lazy_functions : Array[String] = ["IF", "IFERROR", "IFNA"]

// ---------------------------------------------------------------- 聚合

///|
/// 聚合种类。
priv enum AggKind {
  Sum
  Product
  Average
  Min
  Max
  Median
}

///|
/// 收集参与聚合的数字。
///
/// 返回 `Err(e)` 表示遇到了必须传播的错误；`Ok(nums)` 里的数字才是要聚合的。
fn collect_numbers(
  args : Array[Arg],
) -> Result[Array[Double], @value.CalcError] {
  let nums : Array[Double] = []
  for arg in args {
    match arg {
      Scalar(v) => {
        // 字面量实参要强制转换：SUM("2") 是 2，SUM("abc") 是 #VALUE!
        // 空参数（`SUM(1,,3)` 中间那个）直接跳过，与 Excel 一致。
        if v.is_blank() {
          continue
        }
        match v.as_number() {
          Ok(d) => nums.push(d)
          Err(e) => return Err(e)
        }
      }
      Cell(v) =>
        // 引用来的单个值：与区域元素同规则 —— 忽略文本与空值
        match cell_element(v) {
          Ok(Some(d)) => nums.push(d)
          Ok(None) => ()
          Err(e) => return Err(e)
        }
      List(values) =>
        for v in values {
          match cell_element(v) {
            Ok(Some(d)) => nums.push(d)
            Ok(None) => ()
            Err(e) => return Err(e)
          }
        }
    }
  }
  Ok(nums)
}

///|
/// 单元格来源的值在聚合里的处理：数字与逻辑值计入，文本与空值跳过，错误传播。
fn cell_element(v : @value.Value) -> Result[Double?, @value.CalcError] {
  match v {
    @value.Number(d) => Ok(Some(d))
    @value.Bool(b) => Ok(Some(if b { 1.0 } else { 0.0 }))
    @value.Error(e) => Err(e)
    _ => Ok(None)
  }
}

///|
fn aggregate(args : Array[Arg], kind : AggKind) -> @value.Value {
  let nums = match collect_numbers(args) {
    Ok(n) => n
    Err(e) => return @value.Error(e)
  }
  if nums.length() == 0 {
    // 空的聚合：求和与乘积有单位元，其余（平均、最值、中位数）在数学上无定义
    return match kind {
      Sum => @value.Number(0.0)
      Product => @value.Number(1.0)
      _ => @value.Error(@value.DivByZero)
    }
  }
  match kind {
    Sum => @value.Number(fold(nums, 0.0, add_d))
    Product => @value.Number(fold(nums, 1.0, mul_d))
    Average => @value.Number(fold(nums, 0.0, add_d) / nums.length().to_double())
    Min => @value.Number(extremum(nums, true))
    Max => @value.Number(extremum(nums, false))
    Median => @value.Number(median(nums))
  }
}

///|
/// 把任意形态的实参摊平成值数组。
///
/// 给那些**不关心实参来源**的函数用（计数、逻辑、文本拼接）——
/// 它们对"写在公式里的字面量"与"来自单元格"没有不同处理。
fn flatten(arg : Arg) -> Array[@value.Value] {
  match arg {
    Scalar(v) => [v]
    Cell(v) => [v]
    List(values) => values
  }
}

///|
/// 取实参里的单个值（`List` 取第一个）。空列表与缺失都给 `Blank`。
fn single_value(arg : Arg) -> @value.Value {
  match arg {
    Scalar(v) => v
    Cell(v) => v
    List(values) => if values.length() == 0 { @value.Blank } else { values[0] }
  }
}

///|
fn count_numbers(args : Array[Arg]) -> @value.Value {
  let mut n = 0
  for arg in args {
    // `COUNT(1,,3)` 在电子表格里是 **2** —— 空参数不是数字，不计数。
    match arg {
      Scalar(v) => {
        if v.is_blank() {
          continue
        }
        match v.as_number() {
          Ok(_) => n = n + 1
          Err(e) => return @value.Error(e)
        }
      }
      _ =>
        for v in flatten(arg) {
          match v {
            @value.Number(_) => n = n + 1
            @value.Error(e) => return @value.Error(e)
            _ => ()
          }
        }
    }
  }
  @value.Number(n.to_double())
}

///|
fn count_nonblank(args : Array[Arg]) -> @value.Value {
  let mut n = 0
  for arg in args {
    // 空参数既不是"有内容"，也不是"空单元格"—— 两种计数都不算它
    match arg {
      Scalar(v) => if !v.is_blank() { n = n + 1 }
      _ =>
        for v in flatten(arg) {
          if !v.is_blank() {
            n = n + 1
          }
        }
    }
  }
  @value.Number(n.to_double())
}

///|
fn count_blank(args : Array[Arg]) -> @value.Value {
  let mut n = 0
  for arg in args {
    // 只统计**单元格**里的空值；空参数不算
    match arg {
      Scalar(_) => ()
      _ =>
        for v in flatten(arg) {
          if v.is_blank() {
            n = n + 1
          }
        }
    }
  }
  @value.Number(n.to_double())
}

// ---------------------------------------------------------------- 数学

///|
priv enum NumFn1 {
  AbsFn
  IntFn
  SignFn
  SqrtFn
}

///|
priv enum NumFn2 {
  PowFn
  ModFn
}

///|
/// 取第一个实参（标量或仅含一个元素的列表），没有则 `Blank`。
fn first_arg(args : Array[Arg]) -> @value.Value {
  if args.length() == 0 {
    return @value.Blank
  }
  single_value(args[0])
}

///|
fn unary_number(args : Array[Arg], f : NumFn1) -> @value.Value {
  let v = first_arg(args)
  let d = match v.as_number() {
    Ok(d) => d
    Err(e) => return @value.Error(e)
  }
  match f {
    AbsFn => @value.Number(if d < 0.0 { -d } else { d })
    // INT 是**向下取整**（不是向零取整）：INT(-1.5) = -2
    IntFn => @value.Number(floor_double(d))
    SignFn =>
      @value.Number(if d > 0.0 { 1.0 } else if d < 0.0 { -1.0 } else { 0.0 })
    SqrtFn =>
      if d < 0.0 {
        @value.Error(@value.Num)
      } else {
        @value.Number(sqrt_double(d))
      }
  }
}

///|
fn binary_number(args : Array[Arg], f : NumFn2) -> @value.Value {
  if args.length() < 2 {
    return @value.Error(@value.ValueType)
  }
  let a = match arg_at(args, 0).as_number() {
    Ok(d) => d
    Err(e) => return @value.Error(e)
  }
  let b = match arg_at(args, 1).as_number() {
    Ok(d) => d
    Err(e) => return @value.Error(e)
  }
  match f {
    PowFn => @value.Number(pow_double(a, b))
    ModFn =>
      if b == 0.0 {
        @value.Error(@value.DivByZero)
      } else {
        // 电子表格的 MOD 结果符号跟随除数（与某些语言的 % 不同）
        let r = a - b * floor_double(a / b)
        @value.Number(r)
      }
  }
}

///|
fn arg_at(args : Array[Arg], index : Int) -> @value.Value {
  if index >= args.length() {
    return @value.Blank
  }
  single_value(args[index])
}

///|
fn round_fn(args : Array[Arg]) -> @value.Value {
  let v = first_arg(args)
  let d = match v.as_number() {
    Ok(d) => d
    Err(e) => return @value.Error(e)
  }
  let digits = match arg_at(args, 1).as_number() {
    Ok(n) => n.to_int()
    Err(_) => 0
  }
  let scale = pow_double(10.0, digits.to_double())
  // 四舍五入：加 0.5 后向下取整对负数是错的，所以按符号分别处理
  let scaled = d * scale
  let rounded = if scaled >= 0.0 {
    floor_double(scaled + 0.5)
  } else {
    -floor_double(-scaled + 0.5)
  }
  @value.Number(rounded / scale)
}

///|
/// 向下取整。
pub fn floor_double(n : Double) -> Double {
  let t = n.to_int().to_double()
  if n < 0.0 && t != n {
    t - 1.0
  } else {
    t
  }
}

///|
/// 平方根（牛顿迭代）。
///
/// 自己实现而不是用库函数：数值函数的行为必须**可复现**，
/// 而不同后端（native / wasm / js）的内置数学库精度可能不同。
/// 固定迭代次数 + 固定初值，保证同一输入在任何后端得到同一结果。
pub fn sqrt_double(n : Double) -> Double {
  if n <= 0.0 {
    return 0.0
  }
  let mut guess = n
  if guess < 1.0 {
    guess = 1.0
  }
  let mut i = 0
  while i < 60 {
    guess = 0.5 * (guess + n / guess)
    i = i + 1
  }
  guess
}

///|
/// 幂运算，整数指数走快速幂（**避免调用 libm 的 pow**，理由同 `sqrt_double`）。
pub fn pow_double(base : Double, exponent : Double) -> Double {
  if exponent == floor_double(exponent) &&
    exponent >= -1024.0 &&
    exponent <= 1024.0 {
    let mut e = exponent.to_int()
    let mut b = base
    let mut acc = 1.0
    let negative = e < 0
    if negative {
      e = -e
    }
    while e > 0 {
      if e % 2 == 1 {
        acc = acc * b
      }
      b = b * b
      e = e / 2
    }
    if negative {
      1.0 / acc
    } else {
      acc
    }
    // 非整数指数：暂未实现，交给调用方按 #NUM! 处理
    // （电子表格里这类用法极少，而实现一个可复现的 exp/log 需要更多工作）
  } else if base < 0.0 {
    0.0 / 0.0
  } else {
    // 用 exp(y·ln x) 的粗略近似不合适，这里明确返回 NaN 由上层转 #NUM!
    0.0 / 0.0
  }
}

// ---------------------------------------------------------------- 逻辑

///|
fn logical_all(args : Array[Arg], _flag : Bool) -> @value.Value {
  let mut saw_any = false
  for arg in args {
    let values = flatten(arg)
    for v in values {
      // 聚合里的空值与文本按电子表格规则跳过
      match v {
        @value.Blank | @value.Text(_) => continue
        _ => ()
      }
      saw_any = true
      match v.as_bool() {
        Ok(false) => return @value.Bool(false)
        Ok(true) => ()
        Err(e) => return @value.Error(e)
      }
    }
  }
  if saw_any {
    @value.Bool(true)
  } else {
    @value.Error(@value.ValueType)
  }
}

///|
fn logical_any(args : Array[Arg], _flag : Bool) -> @value.Value {
  let mut saw_any = false
  for arg in args {
    let values = flatten(arg)
    for v in values {
      match v {
        @value.Blank | @value.Text(_) => continue
        _ => ()
      }
      saw_any = true
      match v.as_bool() {
        Ok(true) => return @value.Bool(true)
        Ok(false) => ()
        Err(e) => return @value.Error(e)
      }
    }
  }
  if saw_any {
    @value.Bool(false)
  } else {
    @value.Error(@value.ValueType)
  }
}

///|
fn logical_not(args : Array[Arg]) -> @value.Value {
  match first_arg(args).as_bool() {
    Ok(b) => @value.Bool(!b)
    Err(e) => @value.Error(e)
  }
}

///|
priv enum IsKind {
  IsErrorKind
  IsBlankKind
  IsNumberKind
  IsTextKind
  IsLogicalKind
}

///|
/// `IS*` 系列**不传播错误** —— 它们的存在意义就是检测错误。
fn is_kind(args : Array[Arg], kind : IsKind) -> @value.Value {
  let v = first_arg(args)
  let result = match kind {
    IsErrorKind => v.is_error()
    IsBlankKind => v.is_blank()
    IsNumberKind => v.is_number()
    IsTextKind =>
      match v {
        @value.Text(_) => true
        _ => false
      }
    IsLogicalKind =>
      match v {
        @value.Bool(_) => true
        _ => false
      }
  }
  @value.Bool(result)
}

///|
fn is_na(args : Array[Arg]) -> @value.Value {
  let v = first_arg(args)
  @value.Bool(v == @value.Error(@value.NotAvailable))
}

// ---------------------------------------------------------------- 文本

///|
priv enum TextFn {
  UpperFn
  LowerFn
  TrimFn
}

///|
fn text_len(args : Array[Arg]) -> @value.Value {
  let v = first_arg(args)
  if v.is_error() {
    return v
  }
  @value.Number(v.as_text().char_length().to_double())
}

///|
fn text_map(args : Array[Arg], f : TextFn) -> @value.Value {
  let v = first_arg(args)
  if v.is_error() {
    return v
  }
  let s = v.as_text()
  let out = match f {
    UpperFn => map_chars(s, 'a', 'z', -32)
    LowerFn => map_chars(s, 'A', 'Z', 32)
    // TRIM 去掉首尾空白并把中间连续空白压缩成一个空格
    TrimFn => collapse_whitespace(s)
  }
  @value.Text(out)
}

///|
fn text_concat(args : Array[Arg]) -> @value.Value {
  let buf = StringBuilder::StringBuilder()
  for arg in args {
    let values = flatten(arg)
    for v in values {
      if v.is_error() {
        return v
      }
      buf.write_string(v.as_text())
    }
  }
  @value.Text(buf.to_string())
}

///|
/// 只改 ASCII 字母；中文等多字节字符原样保留。
fn map_chars(s : StringView, lo : Char, hi : Char, delta : Int) -> String {
  let buf = StringBuilder::StringBuilder()
  for ch in s {
    if ch >= lo && ch <= hi {
      buf.write_char(shift_char(ch, delta))
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// 对 ASCII 字母做大小写位移（查表，避免整数→字符转换 API）。
///
/// `delta` 只用来判断方向：负数是小写转大写，正数是大写转小写。
/// 下标始终是"字母在 A..Z 里的序号"（0..25）—— 大小写共用同一段序号，
/// 所以**不该**把 `delta` 加进下标。早期版本加了，直接查表越界崩溃，
/// 由单元测试抓出。
fn shift_char(ch : Char, delta : Int) -> Char {
  let base = if delta < 0 { 'a' } else { 'A' }
  let index = ch.to_int() - base.to_int()
  let table : Array[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ]
  table[index]
}

///|
fn collapse_whitespace(s : StringView) -> String {
  let buf = StringBuilder::StringBuilder()
  let mut pending_space = false
  let mut wrote_any = false
  for ch in s {
    let space = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
    if space {
      if wrote_any {
        pending_space = true
      }
    } else {
      if pending_space {
        buf.write_char(' ')
        pending_space = false
      }
      buf.write_char(ch)
      wrote_any = true
    }
  }
  buf.to_string()
}

// ---------------------------------------------------------------- 数值工具

///|
fn fold(
  values : Array[Double],
  init : Double,
  f : (Double, Double) -> Double,
) -> Double {
  let mut acc = init
  for v in values {
    acc = f(acc, v)
  }
  acc
}

///|
fn add_d(a : Double, b : Double) -> Double {
  a + b
}

///|
fn mul_d(a : Double, b : Double) -> Double {
  a * b
}

///|
fn extremum(values : Array[Double], want_min : Bool) -> Double {
  let mut best = values[0]
  for v in values {
    if want_min {
      if v < best {
        best = v
      }
    } else if v > best {
      best = v
    }
  }
  best
}

///|
/// 中位数：排序后取中间；偶数个取中间两个的算术平均。
fn median(values : Array[Double]) -> Double {
  let sorted = sort_doubles(values)
  let n = sorted.length()
  if n % 2 == 1 {
    sorted[n / 2]
  } else {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  }
}

///|
fn sort_doubles(values : Array[Double]) -> Array[Double] {
  let out : Array[Double] = []
  for v in values {
    out.push(v)
  }
  // 插入排序：函数实参数量本来就小，且天然稳定
  let mut i = 1
  while i < out.length() {
    let key = out[i]
    let mut j = i
    while j > 0 && key < out[j - 1] {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = key
    i = i + 1
  }
  out
}
