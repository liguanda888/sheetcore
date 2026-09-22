///|
/// 白盒测试：依赖图、脏传播、拓扑排序、环检测。

///|
fn graph_of(entries : Array[(String, Array[String])]) -> DepGraph {
  let g = DepGraph::new()
  for e in entries {
    g.set_precedents(e.0, e.1)
  }
  g
}

///|
test "records both directions of every edge" {
  let g = graph_of([("B1", ["A1"])])
  assert_eq(g.direct_precedents("B1"), ["A1"])
  assert_eq(g.direct_dependents("A1"), ["B1"])
  // 没有的边返回空数组，而不是报错
  assert_eq(g.direct_precedents("A1"), [])
  assert_eq(g.direct_dependents("B1"), [])
}

///|
test "replacing precedents removes the old edges" {
  // 用户把 =A1+1 改成 =C1+1 时，A1→本格 这条边必须消失，
  // 否则每次改 A1 都会触发一次多余的重算，而且会一直累积。
  let g = graph_of([("B1", ["A1"])])
  g.set_precedents("B1", ["C1"])
  assert_eq(g.direct_precedents("B1"), ["C1"])
  assert_eq(g.direct_dependents("A1"), [])
  assert_eq(g.direct_dependents("C1"), ["B1"])
}

///|
test "clearing precedents turns a formula into a literal" {
  let g = graph_of([("B1", ["A1", "A2"])])
  g.clear_precedents("B1")
  assert_eq(g.direct_precedents("B1"), [])
  assert_eq(g.direct_dependents("A1"), [])
  assert_eq(g.direct_dependents("A2"), [])
}

///|
test "duplicate precedents are collapsed" {
  let g = graph_of([("B1", ["A1", "A1", "A1"])])
  assert_eq(g.direct_precedents("B1"), ["A1"])
}

///|
test "affected_by walks the reverse edges transitively" {
  // A1 → B1 → C1
  let g = graph_of([("B1", ["A1"]), ("C1", ["B1"])])
  let affected = g.affected_by(["A1"])
  // 含种子自己
  assert_eq(sort_keys(affected), ["A1", "B1", "C1"])
  // 改末端只影响自己
  assert_eq(g.affected_by(["C1"]), ["C1"])
  // 互不相干的分支不会被牵连
  let g2 = graph_of([("B1", ["A1"]), ("D1", ["C1"])])
  assert_eq(sort_keys(g2.affected_by(["A1"])), ["A1", "B1"])
}

///|
test "affected_by handles a diamond without visiting twice" {
  //   A1
  //  /  \
  // B1   C1
  //  \  /
  //   D1
  let g = graph_of([("B1", ["A1"]), ("C1", ["A1"]), ("D1", ["B1", "C1"])])
  assert_eq(sort_keys(g.affected_by(["A1"])), ["A1", "B1", "C1", "D1"])
}

///|
test "affected_by terminates on a cycle" {
  // 有环也不能死循环 —— 脏传播用 seen 集合兜住
  let g = graph_of([("A1", ["B1"]), ("B1", ["A1"])])
  assert_eq(sort_keys(g.affected_by(["A1"])), ["A1", "B1"])
}

// ---------------------------------------------------------------- 拓扑排序

///|
test "topological_order puts precedents before dependents" {
  let g = graph_of([("B1", ["A1"]), ("C1", ["B1"]), ("D1", ["A1"])])
  let topo = g.topological_order(["A1", "B1", "C1", "D1"])
  assert_eq(topo.cycles, [])
  assert_eq(topo.order, ["A1", "B1", "C1", "D1"])
  // 除了比对具体顺序（那是实现的产物），也直接断言我们要保证的性质：
  // **每个格子的前置都排在它前面**。
  let mut i = 0
  for cell in topo.order {
    for p in g.direct_precedents(cell) {
      if contains(topo.order, p) {
        assert_true(index_in(topo.order, p) < i)
      }
    }
    i = i + 1
  }
}

///|
fn index_in(items : Array[String], value : String) -> Int {
  let mut i = 0
  for item in items {
    if item == value {
      return i
    }
    i = i + 1
  }
  -1
}

///|
test "topological_order is deterministic: lexicographically smallest first" {
  // 同一张图重复排序必须得到完全相同的顺序，
  // 否则"重算轨迹可复现"这个承诺就是假的。
  let g = graph_of([("D1", ["A1"]), ("C1", ["A1"]), ("B1", ["A1"])])
  let nodes = ["A1", "B1", "C1", "D1"]
  let first = g.topological_order(nodes)
  let second = g.topological_order(nodes)
  assert_eq(first, second)
  // 就绪集合里有 B1/C1/D1 时，取字典序最小的 B1
  assert_eq(first.order, ["A1", "B1", "C1", "D1"])
}

///|
test "topological_order only considers the given subset" {
  // 增量重算的关键：C1 依赖 B1，但 B1 不在子集里，
  // 那就不该成为 C1 的前置约束（它已经算好了）。
  let g = graph_of([("B1", ["A1"]), ("C1", ["B1"])])
  let topo = g.topological_order(["C1"])
  assert_eq(topo.order, ["C1"])
  assert_eq(topo.cycles, [])
}

// ---------------------------------------------------------------- 环

///|
test "detects a self reference as a cycle" {
  // A1 = A1 + 1
  let g = graph_of([("A1", ["A1"])])
  let topo = g.topological_order(["A1"])
  assert_eq(topo.order, [])
  assert_eq(topo.cycles, ["A1"])
  assert_true(g.has_cycle())
}

///|
test "detects a mutual cycle and still orders the rest" {
  // A1 ↔ B1 成环，C1 只是依赖 A1 —— C1 也排不出来（它的前置永远算不完）
  let g = graph_of([("A1", ["B1"]), ("B1", ["A1"]), ("C1", ["A1"])])
  let topo = g.topological_order(["A1", "B1", "C1"])
  assert_eq(topo.order, [])
  assert_eq(topo.cycles, ["A1", "B1", "C1"])
}

///|
test "a cycle does not prevent unrelated cells from being ordered" {
  // 这是用 TopoResult 而不是 Result 的理由：环之外的部分照常能算。
  let g = graph_of([("A1", ["B1"]), ("B1", ["A1"]), ("D1", ["C1"])])
  let topo = g.topological_order(["A1", "B1", "C1", "D1"])
  assert_eq(topo.cycles, ["A1", "B1"])
  assert_eq(topo.order, ["C1", "D1"])
}

///|
test "a long cycle is fully reported" {
  let g = graph_of([("A1", ["C1"]), ("B1", ["A1"]), ("C1", ["B1"])])
  let topo = g.topological_order(["A1", "B1", "C1"])
  assert_eq(topo.order, [])
  assert_eq(topo.cycles, ["A1", "B1", "C1"])
}

///|
test "find_cycle_through returns the path back to the start" {
  let g = graph_of([("A1", ["B1"]), ("B1", ["A1"])])
  match g.find_cycle_through("A1") {
    Some(path) => {
      // 路径首尾都应是起点
      assert_eq(path[0], "A1")
      assert_eq(path[path.length() - 1], "A1")
    }
    None => abort("A1 在环里，应该能找到路径")
  }
  // 不在环里的格子返回 None
  let g2 = graph_of([("B1", ["A1"])])
  assert_true(g2.find_cycle_through("A1") is None)
}

///|
test "all_cells includes both ends of every edge" {
  let g = graph_of([("B1", ["A1"])])
  assert_eq(sort_keys(g.all_cells()), ["A1", "B1"])
}

// ---------------------------------------------------------------- 排序工具

///|
test "sort_keys orders by code point and is stable for duplicates" {
  assert_eq(sort_keys(["B", "A", "C"]), ["A", "B", "C"])
  assert_eq(sort_keys(["A10", "A2", "A1"]), ["A1", "A10", "A2"])
  assert_eq(sort_keys([]), [])
}
