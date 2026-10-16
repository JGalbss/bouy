function buildGraph(edges: [string, string][]): Map<string, string[]> {
  const graph = new Map<string, string[]>();
  for (const [from, to] of edges) {
    const outgoing = graph.get(from) ?? [];
    outgoing.push(to);
    graph.set(from, outgoing);
    if (!graph.has(to)) graph.set(to, []);
  }
  return graph;
}

function bfs(graph: Map<string, string[]>, start: string, goal: string): string[] {
  const previous = new Map<string, string>();
  const visited = new Set<string>([start]);
  let queue = [start];
  while (queue.length > 0) {
    const [current, ...remaining] = queue;
    queue = remaining;
    if (current === goal) {
      const path = [goal];
      let step = goal;
      while (previous.has(step)) {
        step = previous.get(step) as string;
        path.unshift(step);
      }
      return path;
    }
    for (const next of graph.get(current) ?? []) {
      if (visited.has(next)) continue;
      visited.add(next);
      previous.set(next, current);
      queue.push(next);
    }
  }
  return [];
}

function topologicalOrder(graph: Map<string, string[]>): string[] {
  const indegree = new Map<string, number>();
  for (const node of graph.keys()) indegree.set(node, 0);
  for (const targets of graph.values()) {
    for (const t of targets) indegree.set(t, (indegree.get(t) ?? 0) + 1);
  }
  let ready = [...indegree.entries()]
    .filter(([, d]) => d === 0)
    .map(([n]) => n)
    .sort();
  const order: string[] = [];
  while (ready.length > 0) {
    const node = ready[0];
    ready = ready.slice(1);
    order.push(node);
    for (const t of graph.get(node) ?? []) {
      const d = (indegree.get(t) ?? 0) - 1;
      indegree.set(t, d);
      if (d === 0) ready = [...ready, t].sort();
    }
  }
  return order;
}

function main(): void {
  const graph = buildGraph([
    ["a", "b"],
    ["a", "c"],
    ["b", "d"],
    ["c", "d"],
    ["d", "e"],
    ["f", "e"],
  ]);
  console.log(bfs(graph, "a", "e").join(" -> "));
  console.log(bfs(graph, "e", "a").length);
  console.log(topologicalOrder(graph).join(","));
}

main();
