///|
/// 查找类函数：`VLOOKUP` / `HLOOKUP` / `MATCH` / `INDEX`。
///
/// 这四个函数是**二维的** —— 它们要按行列索引，而不是把区域当成一串值。
/// 这就是 `Arg::List` 必须带上行列数的原因：扁平数组区分不了
/// "第 3 个"与"第 2 行第 1 列"。
///
/// 匹配一律用 `@value.compare`（数字 < 文本 < 逻辑值，见 `value/`），
/// 因此跨类型查找也有确定结果，而不是随实现变化。

///|
/// 从实参里取出网格（值 + 行数 + 列数）。
///
/// 只接受 `List`（区域）与 `Cell`（单个格子当 1×1 网格）。
/// **字面量不算表格**：`VLOOKUP(1, 2, 1)` 是写错了，应当报类型错误，
/// 而不是被当成一张 1×1 的表而"成功"。
fn grid_of(arg : Arg) -> (Array[@value.Value], Int, Int)? {
  match arg {
    List(values, rows, cols) => Some((values, rows, cols))
    Cell(v) => Some(([v], 1, 1))
    Scalar(_) => None
  }
}

///|
/// 网格取值；越界返回 `None`（下标是 0 基）。
fn grid_at(
  values : Array[@value.Value],
  cols : Int,
  row : Int,
  col : Int,
) -> @value.Value? {
  let index = row * cols + col
  if row < 0 || col < 0 || col >= cols || index < 0 || index >= values.length() {
    None
  } else {
    Some(values[index])
  }
}

///|
/// 第一个实参的整数值；失败时给出错误原因。
fn int_arg(args : Array[Arg], index : Int) -> Result[Int, @value.CalcError] {
  if index >= args.length() {
    return Err(@value.ValueType)
  }
  let v = single_value(args[index])
  match v.as_number() {
    Ok(d) => Ok(d.to_int())
    Err(e) => Err(e)
  }
}

///|
/// 第 4 个实参（range_lookup）：省略或写 TRUE 表示近似匹配。
///
/// 电子表格的默认值是 `TRUE`（近似），这一点反直觉但必须跟随 ——
/// 用户写 `VLOOKUP(x, t, 2)` 时期望的就是近似匹配。
fn approximate_arg(args : Array[Arg], index : Int) -> Bool {
  if index >= args.length() {
    return true
  }
  match single_value(args[index]).as_bool() {
    Ok(b) => b
    // 该位置是空参数（`VLOOKUP(x,t,2,)`）时按默认值处理
    Err(_) => true
  }
}

///|
/// 在某一列里精确查找，返回 0 基行号。
fn find_exact(
  values : Array[@value.Value],
  rows : Int,
  cols : Int,
  needle : @value.Value,
  col : Int,
) -> Int? {
  let mut i = 0
  while i < rows {
    match grid_at(values, cols, i, col) {
      Some(v) => if @value.compare(v, needle) == 0 { return Some(i) }
      None => ()
    }
    i = i + 1
  }
  None
}

///|
/// 在某一列里近似查找：返回**满足 `值 <= 待查值` 的最后一行**。
///
/// 电子表格假定这一列是升序的。这里不做排序、也不报错，而是取最后一个
/// 满足条件的行 —— 对升序数据等价于"最大的不超过待查值的那个"，
/// 对无序数据也给出**确定**的结果，而不是随实现变化。
fn find_approx(
  values : Array[@value.Value],
  rows : Int,
  cols : Int,
  needle : @value.Value,
  col : Int,
) -> Int? {
  let mut best : Int? = None
  let mut i = 0
  while i < rows {
    match grid_at(values, cols, i, col) {
      Some(v) => if @value.compare(v, needle) <= 0 { best = Some(i) }
      None => ()
    }
    i = i + 1
  }
  best
}

///|
/// `VLOOKUP(待查值, 区域, 列号, [是否近似])`
///
/// 在区域的**第一列**里找待查值，命中则返回同一行第 `列号` 列的值。
/// `列号` 是 **1 基**（第 1 列是 1，不是 0）。
fn lookup_vlookup(args : Array[Arg]) -> @value.Value {
  if args.length() < 3 {
    return @value.Error(@value.ValueType)
  }
  let needle = single_value(args[0])
  if needle.is_error() {
    return needle
  }
  let (values, rows, cols) = match grid_of(args[1]) {
    Some(g) => g
    None => return @value.Error(@value.ValueType)
  }
  let col_index = match int_arg(args, 2) {
    Ok(n) => n
    Err(e) => return @value.Error(e)
  }
  // 列号从 1 开始，所以 0 或负数都是写法错误
  if col_index < 1 {
    return @value.Error(@value.ValueType)
  }
  if col_index > cols {
    return @value.Error(@value.Ref)
  }
  let approximate = approximate_arg(args, 3)
  let found = if approximate {
    find_approx(values, rows, cols, needle, 0)
  } else {
    find_exact(values, rows, cols, needle, 0)
  }
  match found {
    Some(row) =>
      match grid_at(values, cols, row, col_index - 1) {
        Some(v) => v
        None => @value.Error(@value.Ref)
      }
    None => @value.Error(@value.NotAvailable)
  }
}

///|
/// `HLOOKUP(待查值, 区域, 行号, [是否近似])` —— `VLOOKUP` 的横向版本：
/// 在**第一行**里找，返回同一列第 `行号` 行的值。
fn lookup_hlookup(args : Array[Arg]) -> @value.Value {
  if args.length() < 3 {
    return @value.Error(@value.ValueType)
  }
  let needle = single_value(args[0])
  if needle.is_error() {
    return needle
  }
  let (values, rows, cols) = match grid_of(args[1]) {
    Some(g) => g
    None => return @value.Error(@value.ValueType)
  }
  let row_index = match int_arg(args, 2) {
    Ok(n) => n
    Err(e) => return @value.Error(e)
  }
  if row_index < 1 {
    return @value.Error(@value.ValueType)
  }
  if row_index > rows {
    return @value.Error(@value.Ref)
  }
  let approximate = approximate_arg(args, 3)
  // 复用列查找：把"第一行"当成一维向量逐个比
  let mut found : Int? = None
  let mut i = 0
  while i < cols {
    match grid_at(values, cols, 0, i) {
      Some(v) => {
        let c = @value.compare(v, needle)
        if approximate {
          if c <= 0 {
            found = Some(i)
          }
        } else if c == 0 {
          found = Some(i)
          break
        }
      }
      None => ()
    }
    i = i + 1
  }
  match found {
    Some(col) =>
      match grid_at(values, cols, row_index - 1, col) {
        Some(v) => v
        None => @value.Error(@value.Ref)
      }
    None => @value.Error(@value.NotAvailable)
  }
}

///|
/// `MATCH(待查值, 一维区域, [匹配方式])`，返回 **1 基位置**。
///
/// 匹配方式：`1`（默认）最大的不超过待查值、`0` 精确、`-1` 最小的不小于待查值。
/// 传进来的区域会被摊平 —— `MATCH` 本来只接受一维向量。
fn lookup_match(args : Array[Arg]) -> @value.Value {
  if args.length() < 2 {
    return @value.Error(@value.ValueType)
  }
  let needle = single_value(args[0])
  if needle.is_error() {
    return needle
  }
  let values = flatten(args[1])
  if values.length() == 0 {
    return @value.Error(@value.NotAvailable)
  }
  let match_type = if args.length() >= 3 {
    match int_arg(args, 2) {
      Ok(n) => n
      Err(_) => 1
    }
  } else {
    1
  }
  match match_type {
    0 => {
      // 精确：第一个相等的位置
      let mut i = 0
      while i < values.length() {
        if @value.compare(values[i], needle) == 0 {
          return @value.Number((i + 1).to_double())
        }
        i = i + 1
      }
      @value.Error(@value.NotAvailable)
    }
    1 => {
      // 升序假定：最大的不超过待查值
      let mut best : Int? = None
      let mut i = 0
      while i < values.length() {
        if @value.compare(values[i], needle) <= 0 {
          best = Some(i)
        }
        i = i + 1
      }
      match best {
        Some(i) => @value.Number((i + 1).to_double())
        None => @value.Error(@value.NotAvailable)
      }
    }
    -1 => {
      // 降序假定：最小的不小于待查值（取**最靠前**的满足者）
      let mut i = 0
      while i < values.length() {
        if @value.compare(values[i], needle) >= 0 {
          return @value.Number((i + 1).to_double())
        }
        i = i + 1
      }
      @value.Error(@value.NotAvailable)
    }
    _ => @value.Error(@value.ValueType)
  }
}

///|
/// `INDEX(区域, 行号, [列号])`，下标是 **1 基**。
///
/// 单行或单列时只给一个下标：电子表格的规则是把它当作该维度上的位置
/// （单行给的是列号、单列给的是行号），而不是报错。
fn lookup_index(args : Array[Arg]) -> @value.Value {
  if args.length() < 2 {
    return @value.Error(@value.ValueType)
  }
  let (values, rows, cols) = match grid_of(args[0]) {
    Some(g) => g
    None => return @value.Error(@value.ValueType)
  }
  let first = match int_arg(args, 1) {
    Ok(n) => n
    Err(e) => return @value.Error(e)
  }
  let (row, col) = if rows == 1 && cols != 1 {
    // 单行：一个下标是列号
    (1, first)
  } else if cols == 1 && rows != 1 {
    // 单列：一个下标是行号
    (first, 1)
  } else if args.length() >= 3 {
    let c = match int_arg(args, 2) {
      Ok(n) => n
      Err(e) => return @value.Error(e)
    }
    (first, c)
  } else {
    (first, 1)
  }
  if row < 1 || col < 1 {
    return @value.Error(@value.Ref)
  }
  match grid_at(values, cols, row - 1, col - 1) {
    Some(v) => v
    None => @value.Error(@value.Ref)
  }
}
