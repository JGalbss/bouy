type Heap = number[];

function push(heap: Heap, value: number): Heap {
  const next = [...heap, value];
  let i = next.length - 1;
  while (i > 0) {
    const parent = Math.floor((i - 1) / 2);
    if (next[parent] <= next[i]) break;
    const tmp = next[parent];
    next[parent] = next[i];
    next[i] = tmp;
    i = parent;
  }
  return next;
}

function pop(heap: Heap): { value: number; heap: Heap } {
  const top = heap[0];
  const last = heap[heap.length - 1];
  const next = heap.slice(0, -1);
  if (next.length === 0) return { value: top, heap: next };
  next[0] = last;
  let i = 0;
  while (true) {
    const left = 2 * i + 1;
    const right = left + 1;
    let smallest = i;
    if (left < next.length && next[left] < next[smallest]) smallest = left;
    if (right < next.length && next[right] < next[smallest]) smallest = right;
    if (smallest === i) break;
    const tmp = next[i];
    next[i] = next[smallest];
    next[smallest] = tmp;
    i = smallest;
  }
  return { value: top, heap: next };
}

function main(): void {
  let heap: Heap = [];
  for (const n of [42, 7, 19, 3, 25, 3, 100, 1]) {
    heap = push(heap, n);
  }
  const drained: number[] = [];
  while (heap.length > 0) {
    const result = pop(heap);
    drained.push(result.value);
    heap = result.heap;
  }
  console.log(drained.join(","));
}

main();
