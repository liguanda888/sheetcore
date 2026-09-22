///|
/// 公式的抽象语法树。
///
/// 设计取舍：**保留源码位置**（`Spanned`）但不放进每个变体里。
/// 位置信息只在报错时需要，把它塞进每个节点会让 AST 的构造与匹配都变啰嗦。
/// 目前报错用 token 级别的位置，够用；将来要做高亮再引入 `Located` 包装。

///|
/// 一元运算符。
pub(all) enum UnaryOp {
  /// 取负 `-A1`
  Neg
  /// 取正 `+A1`（只影响类型判定，不影响数值）
  Pos
  /// 百分号 `A1%`（后缀，等价于除以 100）
  Percent
} derive(Debug, Eq)

///|
/// 二元运算符。**枚举顺序即优先级分组**，见 `precedence()`。
pub(all) enum BinaryOp {
  /// 幂 `^`
  Pow
  /// 乘 `*`
  Mul
  /// 除 `/`
  Div
  /// 加 `+`
  Add
  /// 减 `-`
  Sub
  /// 文本拼接 `&`
  Concat
  /// 等于 `=`
  Eq
  /// 不等于 `<>`
  Ne
  /// 小于 `<`
  Lt
  /// 小于等于 `<=`
  Le
  /// 大于 `>`
  Gt
  /// 大于等于 `>=`
  Ge
} derive(Debug, Eq)

///|
/// 运算符的**显示形式**（回显公式时用）。
pub fn BinaryOp::symbol(self : BinaryOp) -> String {
  match self {
    Pow => "^"
    Mul => "*"
    Div => "/"
    Add => "+"
    Sub => "-"
    Concat => "&"
    Eq => "="
    Ne => "<>"
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
  }
}

///|
pub fn UnaryOp::symbol(self : UnaryOp) -> String {
  match self {
    Neg => "-"
    Pos => "+"
    Percent => "%"
  }
}

///|
/// 表达式节点。
pub(all) enum Expr {
  /// 数字字面量
  NumberLit(Double)
  /// 文本字面量（已去掉外层引号、已还原 `""` 转义）
  TextLit(String)
  /// 逻辑字面量 `TRUE` / `FALSE`
  BoolLit(Bool)
  /// 公式里**写死**的错误值，例如 `=#N/A`
  ErrorLit(@value.CalcError)
  /// 单元格引用
  Ref(@reference.CellRef)
  /// 区域引用
  Range(@reference.RangeRef)
  /// 一元运算
  Unary(UnaryOp, Expr)
  /// 二元运算
  Binary(BinaryOp, Expr, Expr)
  /// 函数调用（函数名已大写化）
  Call(String, Array[Expr])
  /// **空参数**。`IF(A1,,2)` 与 `SUM(1,,3)` 里那个"什么都没写"的位置。
  /// 它与 `Blank` 不是一回事：`Blank` 是空单元格的**值**，
  /// 而这里是"调用方没提供这个参数"，函数需要区别对待（例如 `COUNT` 忽略它）。
  Missing
} derive(Debug, Eq)

///|
/// 构造数字字面量。
pub fn number_lit(n : Double) -> Expr {
  NumberLit(n)
}

///|
/// 表达式里出现的所有单元格引用（**去重、保持出现顺序**）。
///
/// 用途：依赖图建边。区域会被展开成单个引用 —— 一张表的依赖是
/// "我引用了哪些格子"，而不是"我引用了哪个区域"。
pub fn Expr::collect_refs(self : Expr) -> Array[@reference.CellRef] {
  let out : Array[@reference.CellRef] = []
  collect_into(self, out)
  out
}

///|
fn collect_into(e : Expr, out : Array[@reference.CellRef]) -> Unit {
  match e {
    Ref(r) => push_unique(out, r)
    Range(r) =>
      // 区域展开成单个格子。超上限的区域在这里就已经被拒绝过（parse 阶段
      // 不检查，cells() 返回 None）—— 返回 None 时退化成只记两个角，
      // 让上层能给出"区域过大"的错误，而不是悄悄漏掉依赖。
      match r.cells() {
        Some(cells) =>
          for c in cells {
            push_unique(out, c)
          }
        None => {
          push_unique(out, r.start)
          push_unique(out, r.end)
        }
      }
    Unary(_, inner) => collect_into(inner, out)
    Binary(_, a, b) => {
      collect_into(a, out)
      collect_into(b, out)
    }
    Call(_, args) =>
      for a in args {
        collect_into(a, out)
      }
    _ => ()
  }
}

///|
fn push_unique(out : Array[@reference.CellRef], r : @reference.CellRef) -> Unit {
  let key = r.canonical()
  for existing in out {
    if existing.canonical() == key {
      return
    }
  }
  out.push(r)
}

///|
/// 表达式里用到的函数名（去重、大写、保持出现顺序）。
pub fn Expr::collect_functions(self : Expr) -> Array[String] {
  let out : Array[String] = []
  collect_functions_into(self, out)
  out
}

///|
fn collect_functions_into(e : Expr, out : Array[String]) -> Unit {
  match e {
    Call(name, args) => {
      let mut seen = false
      for existing in out {
        if existing == name {
          seen = true
        }
      }
      if !seen {
        out.push(name)
      }
      for a in args {
        collect_functions_into(a, out)
      }
    }
    Unary(_, inner) => collect_functions_into(inner, out)
    Binary(_, a, b) => {
      collect_functions_into(a, out)
      collect_functions_into(b, out)
    }
    _ => ()
  }
}

///|
/// 把 AST 还原成公式文本（**不含前导 `=`**）。
///
/// 用途：报错时把用户写的公式回显出来、以及测试里做"解析 → 回显 → 再解析"
/// 的往返验证。回显**不保证与原文逐字符相同**（多余括号、大小写会被规范化），
/// 但保证语义相同 —— 这一点由往返测试钉住。
///
/// 优先级低的子表达式会补括号，否则 `(1+2)*3` 会被回显成 `1+2*3`，
/// 语义就变了。
pub fn Expr::to_formula(self : Expr) -> String {
  render(self, 0)
}

///|
/// 运算符优先级：数字越大结合越紧。
fn precedence(op : BinaryOp) -> Int {
  match op {
    Eq | Ne | Lt | Le | Gt | Ge => 1
    Concat => 2
    Add | Sub => 3
    Mul | Div => 4
    Pow => 5
  }
}

///|
/// 中缀渲染：子表达式优先级低于当前上下文时补括号。
fn render(e : Expr, min_prec : Int) -> String {
  match e {
    NumberLit(n) => @value.format_number(n)
    TextLit(s) => quote_formula_string(s)
    BoolLit(b) => if b { "TRUE" } else { "FALSE" }
    ErrorLit(err) => err.literal()
    Ref(r) => r.to_text()
    Range(r) => r.to_text()
    Missing => ""
    Unary(op, inner) => {
      let body = render(inner, 6)
      match op {
        Percent => body + "%"
        Neg => "-" + body
        Pos => "+" + body
      }
    }
    Call(name, args) => {
      let parts : Array[String] = []
      for a in args {
        parts.push(render(a, 0))
      }
      name + "(" + join(parts, ",") + ")"
    }
    Binary(op, a, b) => {
      let prec = precedence(op)
      let left = render(a, prec)
      // 幂是右结合：右侧同级不补括号
      let right = render(b, if op == Pow { prec } else { prec + 1 })
      let text = left + op.symbol() + right
      if prec < min_prec {
        "(" + text + ")"
      } else {
        text
      }
    }
  }
}

///|
/// 文本字面量的公式形式：外层加引号，内部引号翻倍。
pub fn quote_formula_string(s : StringView) -> String {
  let buf = StringBuilder::StringBuilder()
  buf.write_char('"')
  for ch in s {
    if ch == '"' {
      buf.write_string("\"\"")
    } else {
      buf.write_char(ch)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn join(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::StringBuilder()
  let mut first = true
  for p in parts {
    if !first {
      buf.write_string(sep)
    }
    buf.write_string(p)
    first = false
  }
  buf.to_string()
}
