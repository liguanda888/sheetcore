///|
/// 一次重算的**轨迹**。
///
/// 这是"可解释"的载体：调用方能看到这次重算了哪些格子、按什么顺序、
/// 有没有落在环里。顺序是**可复现**的（拓扑排序每一步取字典序最小的就绪节点），
/// 所以同一串操作必然得到同一条轨迹。
///
/// 刻意**不含耗时** —— 耗时取决于机器与调度，放进来会让同一次操作
/// 产生不同的轨迹，违背"可复现"。性能请用独立的基准测试衡量。
pub(all) struct Trace {
  /// 本次真正重算了的格子，**按重算顺序**
  recomputed : Array[String]
  /// 卡在环里、被标记为 `#CYCLE!` 的格子
  cycles : Array[String]
  /// 重算后仍是错误值的格子数（用于一眼看出这次改坏了几处）
  error_cells : Int
  /// 表中一共有多少个有内容的格子（用于对比"重算了几个 / 共几个"）
  total_cells : Int
} derive(Debug, Eq)

///|
/// 工作表：输入、缓存值、依赖图。
pub(all) struct Workbook {
  /// 规范化 key → 用户输入的原文（回显用，保留 `=` 与 `$`）
  raw : Map[String, String]
  /// 规范化 key → 解析结果
  content : Map[String, @formula.CellInput]
  /// 规范化 key → 缓存值
  values : Map[String, @value.Value]
  graph : @graph.DepGraph
  /// 待重算的格子（`set` 时累积，`recalculate` 时清空）
  mut dirty : Array[String]
}

///|
/// 空表。
pub fn Workbook::new() -> Workbook {
  {
    raw: Map([]),
    content: Map([]),
    values: Map([]),
    graph: @graph.DepGraph::new(),
    dirty: [],
  }
}

///|
/// 写入一个格子。`cell_text` 形如 `A1` 或 `Sheet2!A1`；
/// `input_text` 是用户写的内容（`=1+2` 是公式，其余是字面量）。
///
/// 解析失败**不写入**，并把错误返回给调用方 ——
/// 半写入的格子会让依赖图与实际内容不一致。
pub fn Workbook::set(
  self : Workbook,
  cell_text : StringView,
  input_text : StringView,
) -> Result[Unit, @formula.ParseError] {
  let r = match @reference.CellRef::parse(cell_text) {
    Some(r) => r
    None => return Err(@formula.parse_error("Not a valid cell reference", 0))
  }
  let key = r.canonical()
  let parsed = match @formula.parse_cell_input(input_text) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  self.raw.set(key, input_text.to_owned())
  self.content.set(key, parsed)
  // 更新依赖图：公式记录前置，字面量清空前置。
  // 清空前置很关键 —— 把 `=A1+1` 改成 `42` 之后，A1 的变化不该再触发本格重算。
  match parsed {
    @formula.Formula(expr) => {
      let keys : Array[String] = []
      for referenced in expr.collect_refs() {
        let k = referenced.canonical()
        if !@graph.contains(keys, k) {
          keys.push(k)
        }
      }
      self.graph.set_precedents(key, keys)
    }
    @formula.Literal(_) => self.graph.clear_precedents(key)
  }
  if !@graph.contains(self.dirty, key) {
    self.dirty.push(key)
  }
  Ok(())
}

///|
/// 批量写入；遇到第一个错误就停下并返回。已写入的部分保留。
pub fn Workbook::set_many(
  self : Workbook,
  entries : Array[(String, String)],
) -> Result[Unit, @formula.ParseError] {
  for e in entries {
    match self.set(e.0, e.1) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  Ok(())
}

///|
/// 某个格子的当前值。**没有缓存就返回 `Blank`**（不是错误）——
/// 空单元格在电子表格里是正常状态。
pub fn Workbook::value_of(self : Workbook, key : String) -> @value.Value {
  match self.values.get(key) {
    Some(v) => v
    None => @value.Blank
  }
}

///|
/// 某个格子的值（按 `CellRef` 取，自动规范化）。
pub fn Workbook::value_at(
  self : Workbook,
  r : @reference.CellRef,
) -> @value.Value {
  self.value_of(r.canonical())
}

///|
/// 某个格子的显示文本。
pub fn Workbook::display(self : Workbook, key : String) -> String {
  self.value_of(key).display()
}

///|
/// 表里所有有内容的格子（规范化 key，按码位排序以保证顺序稳定）。
pub fn Workbook::keys(self : Workbook) -> Array[String] {
  let out : Array[String] = []
  for entry in self.content.to_array() {
    out.push(entry.0)
  }
  @graph.sort_keys(out)
}

///|
/// **执行一次增量重算**，返回轨迹。
///
/// 流程：脏集合 → 沿反向边扩散出受影响集合 → 只对该子集拓扑排序 →
/// 按序求值。**没有全表扫描，也没有递归求值** ——
/// 求值只读缓存，因此不会出现"算到一半又回头算别人"的情况。
pub fn Workbook::recalculate(self : Workbook) -> Trace {
  let seeds = self.dirty
  self.dirty = []
  let total = self.keys().length()
  if seeds.length() == 0 {
    return {
      recomputed: [],
      cycles: [],
      error_cells: self.count_errors(),
      total_cells: total,
    }
  }
  let affected = self.graph.affected_by(seeds)
  let topo = self.graph.topological_order(affected)
  // 环里的格子直接给 #CYCLE!，不尝试求值（会算不出来）
  for key in topo.cycles {
    self.values.set(key, @value.Error(@value.Cycle))
  }
  for key in topo.order {
    let v = self.compute(key)
    self.values.set(key, v)
  }
  {
    recomputed: topo.order,
    cycles: topo.cycles,
    error_cells: self.count_errors(),
    total_cells: total,
  }
}

///|
/// 统计当前有多少个格子的值是错误。
fn Workbook::count_errors(self : Workbook) -> Int {
  let mut n = 0
  for entry in self.values.to_array() {
    if entry.1.is_error() {
      n = n + 1
    }
  }
  n
}

///|
/// 计算单个格子。
///
/// 注意这里**不会递归求值前置格子**：前置的值已经在拓扑序里先算好并缓存。
/// 这是"增量"能成立的前提，也是避免循环求值的关键。
fn Workbook::compute(self : Workbook, key : String) -> @value.Value {
  match self.content.get(key) {
    None => @value.Blank
    Some(@formula.Literal(v)) => v
    Some(@formula.Formula(expr)) => self.eval(expr)
  }
}

// ---------------------------------------------------------------- 求值

///|
/// 求值一个表达式。
pub fn Workbook::eval(self : Workbook, e : @formula.Expr) -> @value.Value {
  match e {
    @formula.NumberLit(d) => @value.Number(d)
    @formula.TextLit(s) => @value.Text(s)
    @formula.BoolLit(b) => @value.Bool(b)
    @formula.ErrorLit(err) => @value.Error(err)
    // 空参数在值位置上就是空值
    @formula.Missing => @value.Blank
    @formula.Ref(r) => self.value_of(r.canonical())
    // 区域出现在标量位置是类型错误（`=A1:B2+1`）
    @formula.Range(_) => @value.Error(@value.ValueType)
    @formula.Unary(op, inner) => self.eval_unary(op, inner)
    @formula.Binary(op, a, b) => self.eval_binary(op, a, b)
    @formula.Call(name, args) => self.eval_call(name, args)
  }
}

///|
fn Workbook::eval_unary(
  self : Workbook,
  op : @formula.UnaryOp,
  inner : @formula.Expr,
) -> @value.Value {
  let v = self.eval(inner)
  match v {
    // 错误原样传播，不被改写成 #VALUE!
    @value.Error(_) => v
    _ => {
      let d = match v.as_number() {
        Ok(d) => d
        Err(e) => return @value.Error(e)
      }
      match op {
        @formula.Neg => @value.Number(-d)
        @formula.Pos => @value.Number(d)
        @formula.Percent => @value.Number(d / 100.0)
      }
    }
  }
}

///|
fn Workbook::eval_binary(
  self : Workbook,
  op : @formula.BinaryOp,
  a : @formula.Expr,
  b : @formula.Expr,
) -> @value.Value {
  let left = self.eval(a)
  // 短路：`FALSE AND 出错的东西` 不该报错。
  // 算术与比较没有短路语义，但 AND/OR 是函数，不在这里。
  match left {
    @value.Error(_) => return left
    _ => ()
  }
  let right = self.eval(b)
  match right {
    @value.Error(_) => return right
    _ => ()
  }
  apply_binary(op, left, right)
}

///|
/// 二元运算的纯函数部分（实参已求值）。独立出来是为了能脱离表结构测试。
pub fn apply_binary(
  op : @formula.BinaryOp,
  left : @value.Value,
  right : @value.Value,
) -> @value.Value {
  match op {
    @formula.Concat => @value.Text(left.as_text() + right.as_text())
    @formula.Eq => @value.Bool(@value.compare(left, right) == 0)
    @formula.Ne => @value.Bool(@value.compare(left, right) != 0)
    @formula.Lt => @value.Bool(@value.compare(left, right) < 0)
    @formula.Le => @value.Bool(@value.compare(left, right) <= 0)
    @formula.Gt => @value.Bool(@value.compare(left, right) > 0)
    @formula.Ge => @value.Bool(@value.compare(left, right) >= 0)
    _ => {
      let x = match left.as_number() {
        Ok(d) => d
        Err(e) => return @value.Error(e)
      }
      let y = match right.as_number() {
        Ok(d) => d
        Err(e) => return @value.Error(e)
      }
      match op {
        @formula.Add => @value.Number(x + y)
        @formula.Sub => @value.Number(x - y)
        @formula.Mul => @value.Number(x * y)
        @formula.Div =>
          // 除零是**值**，不是异常 —— 一个格子的 #DIV/0! 不该让整张表算不出来
          if y == 0.0 {
            @value.Error(@value.DivByZero)
          } else {
            @value.Number(x / y)
          }
        @formula.Pow => @value.Number(@functions.pow_double(x, y))
        _ => @value.Error(@value.ValueType)
      }
    }
  }
}

///|
/// 函数调用求值。**IF / IFERROR / IFNA 在这里特殊处理（惰性）**，
/// 其余函数先把实参算完再交给函数库。
fn Workbook::eval_call(
  self : Workbook,
  name : String,
  args : Array[@formula.Expr],
) -> @value.Value {
  match name {
    "IF" => {
      // 惰性：`IF(A1=0, 0, 1/A1)` 在 A1=0 时不能计算 1/A1
      let cond = self.eval_arg(args, 0)
      match cond {
        @value.Error(_) => cond
        _ =>
          match cond.as_bool() {
            Ok(true) => self.eval_arg(args, 1)
            Ok(false) => self.eval_arg(args, 2)
            Err(e) => @value.Error(e)
          }
      }
    }
    "IFERROR" => {
      let v = self.eval_arg(args, 0)
      if v.is_error() {
        self.eval_arg(args, 1)
      } else {
        v
      }
    }
    "IFNA" => {
      let v = self.eval_arg(args, 0)
      if v == @value.Error(@value.NotAvailable) {
        self.eval_arg(args, 1)
      } else {
        v
      }
    }
    _ => {
      let done : Array[@functions.Arg] = []
      for a in args {
        done.push(self.eval_to_arg(a))
      }
      @functions.call(name, done)
    }
  }
}

///|
/// 求值第 `i` 个实参；缺失时返回 `Blank`。
fn Workbook::eval_arg(
  self : Workbook,
  args : Array[@formula.Expr],
  i : Int,
) -> @value.Value {
  if i >= args.length() {
    return @value.Blank
  }
  self.eval(args[i])
}

///|
/// 把实参求值成函数库要的形态。
///
/// 三种形态必须分清（详见 `functions.Arg` 的说明）：
/// - `Ref` → `Cell`：**来自单元格**，聚合时忽略文本与空值
/// - `Range` → `List`：区域展开出的多个值
/// - 其余 → `Scalar`：**写在公式里的字面量**，聚合时强制转换
///
/// 把前两种合并会让 `SUM(A1)`（A1 是文本）错误地报 `#VALUE!`，
/// 而电子表格返回 0 —— 这一点由单元测试发现。
///
/// 区域在这里展开而不是在函数库里，是因为只有引擎知道每个格子的当前值；
/// 函数库因此保持"只看得见值"的纯函数形态。
fn Workbook::eval_to_arg(self : Workbook, e : @formula.Expr) -> @functions.Arg {
  match e {
    @formula.Ref(r) => @functions.Cell(self.value_of(r.canonical()))
    @formula.Range(r) =>
      match r.cells() {
        Some(cells) => {
          let values : Array[@value.Value] = []
          for c in cells {
            values.push(self.value_of(c.canonical()))
          }
          @functions.List(values)
        }
        // 区域过大：不能静默当成空，否则 SUM 会给出错误的 0
        None => @functions.List([@value.Error(@value.Num)])
      }
    @formula.Missing => @functions.Scalar(@value.Blank)
    _ => @functions.Scalar(self.eval(e))
  }
}

// ---------------------------------------------------------------- 便捷入口

///|
/// 一步到位：新建表、写入若干格子、重算、返回轨迹。
pub fn evaluate(
  entries : Array[(String, String)],
) -> Result[(Workbook, Trace), @formula.ParseError] {
  let wb = Workbook::new()
  match wb.set_many(entries) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let trace = wb.recalculate()
  Ok((wb, trace))
}

///|
/// 读某个格子的值（先重算再读）。
pub fn evaluate_cell(
  entries : Array[(String, String)],
  cell : StringView,
) -> Result[@value.Value, @formula.ParseError] {
  let wb = Workbook::new()
  match wb.set_many(entries) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let _ = wb.recalculate()
  match @reference.CellRef::parse(cell) {
    Some(r) => Ok(wb.value_of(r.canonical()))
    None => Err(@formula.parse_error("Not a valid cell reference", 0))
  }
}
