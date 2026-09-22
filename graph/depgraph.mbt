///|
/// 单元格依赖图：谁依赖谁，以及"改了谁要重算哪些"。
///
/// 两个方向都存：
/// - `precedents`：我依赖谁 —— 拓扑排序需要（先算前置）
/// - `dependents`：谁依赖我 —— 脏传播需要（改了我，谁要重算）
///
/// 只存一个方向就得反复全表扫描，那就不是增量重算了。
///
/// **环不是被禁止的，而是被检测出来的。** 图允许自环与环存在，
/// 由 `topological_order` 报出来交给上层转成 `#CYCLE!` ——
/// 用户写 `A1=A1+1` 时应当看到错误值，而不是程序崩掉或死循环。

///|
/// 依赖图。key 是**规范化的单元格名**（`CellRef::canonical()`）——
/// `$A$1` 与 `A1` 必须落成同一个 key，否则会漏边。
pub(all) struct DepGraph {
  precedents : Map[String, Array[String]]
  dependents : Map[String, Array[String]]
}

///|
/// 空图。
pub fn DepGraph::new() -> DepGraph {
  { precedents: Map([]), dependents: Map([]), }
}

///|
/// 记录某个格子的直接依赖，**先清掉它的旧边**。
///
/// 为什么必须清旧边：用户把 `=A1+1` 改成 `=B1+1` 时，
/// 若不移除 A1 → 本格 这条边，A1 变化就会触发一次多余的重算，
/// 而且会一直累积下去 —— 增量变成"越算越多"。
pub fn DepGraph::set_precedents(
  self : DepGraph,
  cell : String,
  deps : Array[String],
) -> Unit {
  let old = self.direct_precedents(cell)
  for p in old {
    remove_from(self.dependents, p, cell)
  }
  let unique : Array[String] = []
  for d in deps {
    if !contains(unique, d) {
      unique.push(d)
    }
  }
  self.precedents.set(cell, unique)
  for d in unique {
    add_to(self.dependents, d, cell)
  }
}

///|
/// 某个格子变成字面量（不再是公式）—— 移除它的全部依赖边。
pub fn DepGraph::clear_precedents(self : DepGraph, cell : String) -> Unit {
  self.set_precedents(cell, [])
}

///|
/// 我直接依赖谁。
pub fn DepGraph::direct_precedents(
  self : DepGraph,
  cell : String,
) -> Array[String] {
  match self.precedents.get(cell) {
    Some(a) => a
    None => []
  }
}

///|
/// 谁直接依赖我。
pub fn DepGraph::direct_dependents(
  self : DepGraph,
  cell : String,
) -> Array[String] {
  match self.dependents.get(cell) {
    Some(a) => a
    None => []
  }
}

///|
/// 图里出现过的所有格子（含只有出边、没有入边的）。
pub fn DepGraph::all_cells(self : DepGraph) -> Array[String] {
  let out : Array[String] = []
  for entry in self.precedents.to_array() {
    if !contains(out, entry.0) {
      out.push(entry.0)
    }
  }
  for entry in self.dependents.to_array() {
    if !contains(out, entry.0) {
      out.push(entry.0)
    }
  }
  out
}

///|
/// **脏传播**：从若干变化的格子出发，收集所有需要重算的格子（含它们自己）。
///
/// 结果按**发现顺序**返回（先种子、再一层层扩散），顺序本身不用于计算 ——
/// 真正的重算顺序由 `topological_order` 决定。这里只回答"哪些"。
pub fn DepGraph::affected_by(
  self : DepGraph,
  seeds : Array[String],
) -> Array[String] {
  // 成员判断用 Map，不用数组线性查找。
  //
  // 原来的实现每遇到一个格子就扫一遍已见集合，n 个格子就是 O(n²)。
  // 1 万个格子时这一处就能吃掉几十秒 —— 由基准测试发现（它当时直接跑不完）。
  let seen : Map[String, Unit] = Map([])
  let out : Array[String] = []
  let queue : Array[String] = []
  for s in seeds {
    if !seen.contains(s) {
      seen.set(s, ())
      out.push(s)
      queue.push(s)
    }
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    for next in self.direct_dependents(current) {
      if !seen.contains(next) {
        seen.set(next, ())
        out.push(next)
        queue.push(next)
      }
    }
  }
  out
}

///|
/// 字符串最小堆 —— Kahn 算法里的"就绪集合"。
///
/// 为什么需要它：既要**每次取字典序最小的**（保证轨迹可复现），
/// 又要避免每次扫全表。堆同时满足这两点：取最小 O(log n)，
/// 插入 O(log n)。用有序数组或每次线性扫描都会把排序拖回 O(n²)。
priv struct MinHeap {
  items : Array[String]
}

///|
fn MinHeap::new() -> MinHeap {
  { items: [], }
}

///|
fn MinHeap::push(self : MinHeap, value : String) -> Unit {
  self.items.push(value)
  let mut i = self.items.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if compare_keys(self.items[i], self.items[parent]) < 0 {
      let tmp = self.items[i]
      self.items[i] = self.items[parent]
      self.items[parent] = tmp
      i = parent
    } else {
      break
    }
  }
}

///|
fn MinHeap::pop(self : MinHeap) -> String? {
  let n = self.items.length()
  if n == 0 {
    return None
  }
  let top = self.items[0]
  let last = self.items[n - 1]
  ignore(self.items.pop())
  if n > 1 {
    self.items[0] = last
    let mut i = 0
    while true {
      let left = 2 * i + 1
      let right = 2 * i + 2
      let mut smallest = i
      if left < self.items.length() &&
        compare_keys(self.items[left], self.items[smallest]) < 0 {
        smallest = left
      }
      if right < self.items.length() &&
        compare_keys(self.items[right], self.items[smallest]) < 0 {
        smallest = right
      }
      if smallest == i {
        break
      }
      let tmp = self.items[i]
      self.items[i] = self.items[smallest]
      self.items[smallest] = tmp
      i = smallest
    }
  }
  Some(top)
}

///|
/// 子集拓扑排序的结果。
///
/// 刻意**不用 `Result`**：检测到环时，`Err` 会丢掉"剩下那些可以正常计算"
/// 的顺序，而上层恰恰需要用它 —— 环里的格子给 `#CYCLE!`，
/// 其余照常算完。用 `Result` 就得再排一次，既慢又容易写出不一致。
pub(all) struct TopoResult {
  /// 可以按此顺序计算的格子（每个的前置都在它前面）
  order : Array[String]
  /// 卡在环里的格子（含自环）。它们无法计算，上层应给出 `#CYCLE!`
  cycles : Array[String]
} derive(Debug, Eq)

///|
/// 对**给定的子集**做拓扑排序。
///
/// - `order`：按此顺序重算即可
/// - `cycles`：卡在环里的格子
///
/// 只对子集排序（而不是整张图）正是增量重算的关键：改了 A1，
/// 只需要给受影响的那些格子排序。排序用 **Kahn 算法**，
/// 每一步在就绪集合里取字典序最小的，保证**同一输入得到同一顺序** ——
/// 这让"重算轨迹"可复现，也让测试稳定。
///
/// **复杂度**：成员判断走 `Map`、就绪集合走最小堆，因此是 `O(n log n + m)`。
/// 早期版本用数组做成员判断、每轮扫全表挑最小，实际是 `O(n³)` ——
/// 1 万个格子上直接跑不完，由基准测试发现。
pub fn DepGraph::topological_order(
  self : DepGraph,
  nodes : Array[String],
) -> TopoResult {
  let in_nodes : Map[String, Unit] = Map([])
  for n in nodes {
    in_nodes.set(n, ())
  }
  // 只统计"子集内部"的入边 —— 子集外的依赖不在本次重算范围内。
  let indegree : Map[String, Int] = Map([])
  for n in nodes {
    let precedents = self.direct_precedents(n)
    let mut count = 0
    for p in precedents {
      if in_nodes.contains(p) && p != n {
        count = count + 1
      }
    }
    // 自环：自己依赖自己，永远算不出来。单独计一次，
    // 否则 `p != n` 的过滤会把它漏掉。
    if contains(precedents, n) {
      count = count + 1
    }
    indegree.set(n, count)
  }
  let ready = MinHeap::new()
  for n in nodes {
    if degree_of_map(indegree, n) == 0 {
      ready.push(n)
    }
  }
  let order : Array[String] = []
  let done : Map[String, Unit] = Map([])
  while true {
    let chosen = match ready.pop() {
      Some(n) => n
      None => break
    }
    order.push(chosen)
    done.set(chosen, ())
    for dependent in self.direct_dependents(chosen) {
      if in_nodes.contains(dependent) && !done.contains(dependent) {
        let next = degree_of_map(indegree, dependent) - 1
        indegree.set(dependent, next)
        if next == 0 {
          ready.push(dependent)
        }
      }
    }
  }
  let cycles : Array[String] = []
  for n in nodes {
    if !done.contains(n) {
      cycles.push(n)
    }
  }
  { order, cycles: sort_keys(cycles), }
}

///|
/// 从入度表里取值；缺失按 0 处理。
fn degree_of_map(map : Map[String, Int], key : String) -> Int {
  match map.get(key) {
    Some(v) => v
    None => 0
  }
}

///|
/// 整张图是否有环。
pub fn DepGraph::has_cycle(self : DepGraph) -> Bool {
  self.topological_order(self.all_cells()).cycles.length() > 0
}

///|
/// 找到包含指定格子的环（用于诊断信息）。
///
/// 做法是从该格子出发沿 dependents 走，看能否回到自己。
/// 只用于报错提示，不参与计算。
pub fn DepGraph::find_cycle_through(
  self : DepGraph,
  cell : String,
) -> Array[String]? {
  let path : Array[String] = []
  if dfs_cycle(self, cell, cell, path, []) {
    Some(path)
  } else {
    None
  }
}

///|
fn dfs_cycle(
  g : DepGraph,
  start : String,
  current : String,
  path : Array[String],
  visited : Array[String],
) -> Bool {
  path.push(current)
  for next in g.direct_dependents(current) {
    if next == start {
      path.push(start)
      return true
    }
    if !contains(visited, next) {
      visited.push(next)
      if dfs_cycle(g, start, next, path, visited) {
        return true
      }
    }
  }
  // 这条分支走不通，回溯
  let _ = path.pop()
  false
}

// ---------------------------------------------------------------- 小工具

///|
/// 数组里是否含某个字符串。
pub fn contains(items : Array[String], value : String) -> Bool {
  for item in items {
    if item == value {
      return true
    }
  }
  false
}

///|
fn add_to(
  map : Map[String, Array[String]],
  key : String,
  value : String,
) -> Unit {
  let current = match map.get(key) {
    Some(a) => a
    None => []
  }
  if !contains(current, value) {
    current.push(value)
    map.set(key, current)
  }
}

///|
fn remove_from(
  map : Map[String, Array[String]],
  key : String,
  value : String,
) -> Unit {
  let current = match map.get(key) {
    Some(a) => a
    None => return
  }
  let kept : Array[String] = []
  for item in current {
    if item != value {
      kept.push(item)
    }
  }
  map.set(key, kept)
}

///|
/// 字符串按码位比较（不依赖 locale，保证可复现）。
pub fn compare_keys(a : StringView, b : StringView) -> Int {
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

///|
/// 按码位排序（稳定起见用插入排序，输入规模本就很小）。
pub fn sort_keys(items : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for item in items {
    out.push(item)
  }
  let mut i = 1
  while i < out.length() {
    let key = out[i]
    let mut j = i
    while j > 0 && compare_keys(key, out[j - 1]) < 0 {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = key
    i = i + 1
  }
  out
}

///|
/// 把若干 key 拼成一行，用于错误提示。
pub fn join_keys(items : Array[String]) -> String {
  let buf = StringBuilder::StringBuilder()
  let mut first = true
  for item in items {
    if !first {
      buf.write_string(", ")
    }
    buf.write_string(item)
    first = false
  }
  buf.to_string()
}
