///|
/// 单元格地址：列名与列号互转、单个引用、区域。
///
/// 三件事必须分清，否则依赖图会错：
/// 1. **`$A$1` 与 `A1` 指向同一个格子** —— 依赖关系上等价；
/// 2. 但**回显时要保留 `$`** —— 用户看到的是自己写的形式；
/// 3. 因此提供一个 `canonical()` 作为 Map 的 key，与 `to_text()` 分开。

///|
/// 列数上限：16384 列（A..XFD），与 Excel 一致。
pub let max_columns : Int = 16384

///|
/// 行数上限：1048576 行，与 Excel 一致。
pub let max_rows : Int = 1048576

///|
/// 一个区域最多展开多少个格子。
///
/// 为什么要设上限：`A1:XFD1048576` 是合法写法但有一万七千亿个格子，
/// 展开它会直接耗尽内存。超出上限时**报错而不是静默截断** ——
/// 静默截断会让 `SUM(A1:XFD1048576)` 给出一个看起来正常但错误的答案。
pub let max_range_cells : Int = 1048576

///|
/// 列号 → 列名（`0` → `A`，`25` → `Z`，`26` → `AA`）。
///
/// 注意这是**双射 26 进制**，不是普通进制：没有"0"这个数字，
/// A 代表 1 而不是 0。所以要先 `+1` 再在循环里 `-1`。
pub fn column_name(col : Int) -> String {
  if col < 0 {
    return ""
  }
  let letters : Array[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ]
  let buf = StringBuilder::StringBuilder()
  let mut n = col + 1
  while n > 0 {
    n = n - 1
    // 从低位往高位写，最后反转。
    buf.write_char(letters[n % 26])
    n = n / 26
  }
  reverse(buf.to_string())
}

///|
/// 列名 → 列号（`A` → `0`，`Z` → `25`，`AA` → `26`）。
/// 非法列名（空、含非字母、超上限）返回 `None`。
pub fn column_index(name : StringView) -> Int? {
  let mut value = 0
  let mut count = 0
  for ch in name {
    let upper = if ch >= 'a' && ch <= 'z' { upper_letter(ch) } else { ch }
    if upper < 'A' || upper > 'Z' {
      return None
    }
    value = value * 26 + (upper.to_int() - 'A'.to_int() + 1)
    count = count + 1
    // 提前拦截，避免长字符串把 Int 撑爆。
    if value > max_columns {
      return None
    }
  }
  if count == 0 {
    return None
  }
  Some(value - 1)
}

///|
/// 小写字母 → 大写。
fn upper_letter(ch : Char) -> Char {
  let letters : Array[Char] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ]
  letters[ch.to_int() - 'a'.to_int()]
}

///|
fn reverse(s : StringView) -> String {
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
/// 单元格引用。
///
/// `row` / `col` 都是 **0 基**（`A1` → col 0, row 0），
/// 而 `$` 标记只影响回显，不影响身份。
pub(all) struct CellRef {
  /// 跨表引用时的表名；同表引用为 `None`。
  sheet : String?
  col : Int
  row : Int
  col_abs : Bool
  row_abs : Bool
} derive(Debug, Eq)

///|
/// 构造同表的相对引用。
pub fn cell_ref(col : Int, row : Int) -> CellRef {
  { sheet: None, col, row, col_abs: false, row_abs: false, }
}

///|
/// 解析单个单元格引用，例如 `A1`、`$A$1`、`$A1`、`A$1`、`Sheet2!A1`。
///
/// 表名允许用单引号包起来（`'My Sheet'!A1`），以支持含空格的表名。
pub fn CellRef::parse(text : StringView) -> CellRef? {
  let s = text.trim()
  if s.length() == 0 {
    return None
  }
  let (sheet, body) = match split_sheet(s) {
    Some(pair) => pair
    None => (None, s)
  }
  let chars : Array[Char] = []
  for ch in body {
    chars.push(ch)
  }
  let mut i = 0
  let mut col_abs = false
  if i < chars.length() && chars[i] == '$' {
    col_abs = true
    i = i + 1
  }
  let letter_start = i
  while i < chars.length() && is_letter(chars[i]) {
    i = i + 1
  }
  if i == letter_start {
    return None
  }
  let letters = slice(chars, letter_start, i)
  let col = match column_index(letters) {
    Some(c) => c
    None => return None
  }
  let mut row_abs = false
  if i < chars.length() && chars[i] == '$' {
    row_abs = true
    i = i + 1
  }
  let digit_start = i
  while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
    i = i + 1
  }
  if i == digit_start || i != chars.length() {
    return None
  }
  let digits = slice(chars, digit_start, i)
  let row_number = match parse_positive_int(digits) {
    Some(n) => n
    None => return None
  }
  // 行号 1 基，且 0 与超上限都非法。
  if row_number < 1 || row_number > max_rows {
    return None
  }
  Some({ sheet, col, row: row_number - 1, col_abs, row_abs, })
}

///|
/// 拆出 `表名!` 前缀；没有则返回 `(None, 原文)`。
fn split_sheet(s : StringView) -> (String?, StringView)? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut i = 0
  while i < chars.length() && chars[i] != '!' {
    i = i + 1
  }
  if i >= chars.length() {
    return None
  }
  let raw_name = slice(chars, 0, i)
  if raw_name.length() == 0 {
    return None
  }
  // 用字符数组判断首尾引号，避免 String 下标返回的是码元而不是字符。
  let name = if i >= 2 && chars[0] == '\'' && chars[i - 1] == '\'' {
    // 去掉外层单引号；表名内部的 '' 表示一个真正的单引号。
    unescape_sheet(slice(chars, 1, i - 1))
  } else {
    raw_name
  }
  Some((Some(name), slice_view(chars, i + 1, chars.length())))
}

///|
fn unescape_sheet(s : StringView) -> String {
  let buf = StringBuilder::StringBuilder()
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '\'' && i + 1 < chars.length() && chars[i + 1] == '\'' {
      buf.write_char('\'')
      i = i + 2
    } else {
      buf.write_char(chars[i])
      i = i + 1
    }
  }
  buf.to_string()
}

///|
/// 取字符数组的一段并转成 String。
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
/// 取字符数组的一段并保留为 StringView 语义（这里仍返回 String，
/// 单独留一个名字是为了调用处读起来能分清"切出来再解析"与"原样保留"）。
fn slice_view(chars : Array[Char], from : Int, to : Int) -> StringView {
  slice(chars, from, to)
}

///|
fn is_letter(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

///|
/// 十进制正整数；含非数字、空串、超上限返回 `None`。
fn parse_positive_int(s : StringView) -> Int? {
  let mut value = 0
  let mut count = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      return None
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
    count = count + 1
    if value > max_rows {
      return None
    }
  }
  if count == 0 {
    return None
  }
  Some(value)
}

///|
/// 引用 → 文本，**保留 `$` 与表名**（用户原样的形式）。
pub fn CellRef::to_text(self : CellRef) -> String {
  let buf = StringBuilder::StringBuilder()
  match self.sheet {
    Some(name) => {
      buf.write_string(quote_sheet(name))
      buf.write_char('!')
    }
    None => ()
  }
  if self.col_abs {
    buf.write_char('$')
  }
  buf.write_string(column_name(self.col))
  if self.row_abs {
    buf.write_char('$')
  }
  buf.write_string((self.row + 1).to_string())
  buf.to_string()
}

///|
/// 表名含空格或特殊字符时用单引号包起来。
pub fn quote_sheet(name : String) -> String {
  if needs_quoting(name) {
    let buf = StringBuilder::StringBuilder()
    buf.write_char('\'')
    for ch in name {
      if ch == '\'' {
        // 内部的单引号要写成两个
        buf.write_string("''")
      } else {
        buf.write_char(ch)
      }
    }
    buf.write_char('\'')
    buf.to_string()
  } else {
    name
  }
}

///|
fn needs_quoting(name : StringView) -> Bool {
  if name.length() == 0 {
    return true
  }
  for ch in name {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_'
    if !ok {
      return true
    }
  }
  false
}

///|
/// **身份形式**：丢掉 `$` 与表名之外的差异，用作依赖图与值表的 key。
///
/// 为什么不直接用 `to_text()`：`$A$1` 与 `A1` 是同一个格子，
/// 用 `to_text()` 当 key 会把它当成两个格子 —— 依赖图会漏掉这条边。
pub fn CellRef::canonical(self : CellRef) -> String {
  let buf = StringBuilder::StringBuilder()
  match self.sheet {
    Some(name) => {
      buf.write_string(name)
      buf.write_char('!')
    }
    None => ()
  }
  buf.write_string(column_name(self.col))
  buf.write_string((self.row + 1).to_string())
  buf.to_string()
}

///|
/// 同表同列的另一个引用（不改 `$` 标记）。
pub fn CellRef::same_cell(self : CellRef, other : CellRef) -> Bool {
  self.canonical() == other.canonical()
}

///|
/// 区域引用，例如 `A1:B10`、`$A$1:$B$10`、`Sheet2!A1:B10`。
///
/// 约定：`start` 与 `end` 就是用户写的两个角，**不做行列排序** ——
/// 排序会在回显时改变用户写的形式。展开时再按 min/max 处理。
pub(all) struct RangeRef {
  sheet : String?
  start : CellRef
  end : CellRef
} derive(Debug, Eq)

///|
/// 解析区域；单个引用（`A1`）也接受，此时 start == end。
pub fn RangeRef::parse(text : StringView) -> RangeRef? {
  let s = text.trim()
  if s.length() == 0 {
    return None
  }
  // 用第一个 ':' 拆开（表名里不会出现 ':'，因为表名在 '!' 之前）
  match split_once_char(s, ':') {
    Some((left, right)) => {
      let a = match CellRef::parse(left) {
        Some(r) => r
        None => return None
      }
      let b = match CellRef::parse(right) {
        Some(r) => r
        None => return None
      }
      // 跨表区域必须同表；只写在一侧的 `Sheet2!` 也视为整个区域的表名。
      let sheet = match (a.sheet, b.sheet) {
        (Some(x), Some(y)) => if x != y { return None } else { Some(x) }
        (Some(x), None) => Some(x)
        (None, Some(y)) => Some(y)
        (None, None) => None
      }
      let start = { ..a, sheet: None, }
      let end = { ..b, sheet: None, }
      Some({ sheet, start, end, })
    }
    None =>
      match CellRef::parse(s) {
        Some(r) => {
          let single = { ..r, sheet: None, }
          Some({ sheet: r.sheet, start: single, end: single, })
        }
        None => None
      }
  }
}

///|
fn split_once_char(s : StringView, sep : Char) -> (StringView, StringView)? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut i = 0
  while i < chars.length() && chars[i] != sep {
    i = i + 1
  }
  if i >= chars.length() {
    return None
  }
  Some((slice_view(chars, 0, i), slice_view(chars, i + 1, chars.length())))
}

///|
/// 区域的左上角与右下角（按行列取 min/max）。
pub fn RangeRef::bounds(self : RangeRef) -> (Int, Int, Int, Int) {
  let c1 = if self.start.col < self.end.col {
    self.start.col
  } else {
    self.end.col
  }
  let c2 = if self.start.col < self.end.col {
    self.end.col
  } else {
    self.start.col
  }
  let r1 = if self.start.row < self.end.row {
    self.start.row
  } else {
    self.end.row
  }
  let r2 = if self.start.row < self.end.row {
    self.end.row
  } else {
    self.start.row
  }
  (c1, r1, c2, r2)
}

///|
/// 区域包含多少个格子，**精确值**（用 `Int64`，不会溢出）。
///
/// 为什么必须有个精确版本：`A1:XFD1048576` 有 171 亿个格子，
/// 用 32 位 `Int` 相乘会**回绕成 0** —— 于是"超过上限就拒绝"的判断失效，
/// `cells()` 会静默返回空数组。这个 bug 由单元测试发现。
pub fn RangeRef::exact_cell_count(self : RangeRef) -> Int64 {
  let (c1, r1, c2, r2) = self.bounds()
  let cols = (c2 - c1 + 1).to_int64()
  let rows = (r2 - r1 + 1).to_int64()
  cols * rows
}

///|
/// 区域包含多少个格子，**会饱和**。
///
/// 超过 `max_range_cells` 时返回 `max_range_cells + 1`（而不是回绕）。
/// 调用方只应判断它是否 `> max_range_cells`；需要精确数字请用
/// `exact_cell_count()`。
pub fn RangeRef::cell_count(self : RangeRef) -> Int {
  let exact = self.exact_cell_count()
  if exact > max_range_cells.to_int64() {
    max_range_cells + 1
  } else {
    exact.to_int()
  }
}

///|
/// 展开区域里的所有格子，**按行优先**（先左到右，再上到下）——
/// 与电子表格的阅读顺序一致，也让遍历结果可预测。
///
/// 超过 `max_range_cells` 时返回 `None`，而不是静默截断。
pub fn RangeRef::cells(self : RangeRef) -> Array[CellRef]? {
  let count = self.cell_count()
  if count > max_range_cells {
    return None
  }
  let (c1, r1, c2, r2) = self.bounds()
  let out : Array[CellRef] = []
  let mut row = r1
  while row <= r2 {
    let mut col = c1
    while col <= c2 {
      out.push({ sheet: self.sheet, col, row, col_abs: false, row_abs: false, })
      col = col + 1
    }
    row = row + 1
  }
  Some(out)
}

///|
/// 区域 → 文本（保留 `$`）。
pub fn RangeRef::to_text(self : RangeRef) -> String {
  let buf = StringBuilder::StringBuilder()
  match self.sheet {
    Some(name) => {
      buf.write_string(quote_sheet(name))
      buf.write_char('!')
    }
    None => ()
  }
  buf.write_string(self.start.to_text())
  buf.write_char(':')
  buf.write_string(self.end.to_text())
  buf.to_string()
}

///|
/// 区域的身份形式（`$` 不参与身份）。
pub fn RangeRef::canonical(self : RangeRef) -> String {
  let buf = StringBuilder::StringBuilder()
  match self.sheet {
    Some(name) => {
      buf.write_string(name)
      buf.write_char('!')
    }
    None => ()
  }
  buf.write_string(self.start.canonical())
  buf.write_char(':')
  buf.write_string(self.end.canonical())
  buf.to_string()
}

///|
/// 区域是否只含一个格子。
pub fn RangeRef::is_single(self : RangeRef) -> Bool {
  self.cell_count() == 1
}
