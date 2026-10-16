function quicksort(xs: number[]): number[] {
  if (xs.length <= 1) return xs;
  const [pivot, ...rest] = xs;
  const smaller = rest.filter((x) => x < pivot);
  const larger = rest.filter((x) => x >= pivot);
  return [...quicksort(smaller), pivot, ...quicksort(larger)];
}

function mergeSort(xs: number[]): number[] {
  if (xs.length <= 1) return xs;
  const middle = Math.floor(xs.length / 2);
  const left = mergeSort(xs.slice(0, middle));
  const right = mergeSort(xs.slice(middle));
  const merged: number[] = [];
  let i = 0;
  let j = 0;
  while (i < left.length && j < right.length) {
    if (left[i] <= right[j]) {
      merged.push(left[i]);
      i++;
    } else {
      merged.push(right[j]);
      j++;
    }
  }
  while (i < left.length) merged.push(left[i++]);
  while (j < right.length) merged.push(right[j++]);
  return merged;
}

function bubbleSort(input: number[]): number[] {
  const xs = [...input];
  let swapped = true;
  while (swapped) {
    swapped = false;
    for (let i = 1; i < xs.length; i++) {
      if (xs[i - 1] > xs[i]) {
        const tmp = xs[i];
        xs[i] = xs[i - 1];
        xs[i - 1] = tmp;
        swapped = true;
      }
    }
  }
  return xs;
}

function insertionSort(input: string[]): string[] {
  const xs = [...input];
  for (let i = 1; i < xs.length; i++) {
    const current = xs[i];
    let j = i - 1;
    while (j >= 0 && xs[j] > current) {
      xs[j + 1] = xs[j];
      j--;
    }
    xs[j + 1] = current;
  }
  return xs;
}

function main(): void {
  const data = [38, 27, 43, 3, 9, 82, 10, 3];
  console.log(quicksort(data).join(","));
  console.log(mergeSort(data).join(","));
  console.log(bubbleSort(data).join(","));
  console.log(insertionSort(["delta", "alpha", "charlie", "bravo"]).join(","));
  console.log(data.join(","));
}

main();
