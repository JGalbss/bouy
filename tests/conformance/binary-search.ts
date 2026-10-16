function binarySearch(sorted: number[], target: number): number {
  let low = 0;
  let high = sorted.length - 1;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const value = sorted[mid];
    if (value === target) {
      return mid;
    } else if (value < target) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -(low + 1);
}

function lowerBound(sorted: number[], target: number): number {
  let low = 0;
  let high = sorted.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (sorted[mid] < target) low = mid + 1;
    else high = mid;
  }
  return low;
}

function main(): void {
  const data = [1, 3, 5, 7, 9, 11, 13];
  console.log(binarySearch(data, 7), binarySearch(data, 1), binarySearch(data, 13));
  console.log(binarySearch(data, 4), binarySearch(data, 0), binarySearch(data, 99));
  console.log(lowerBound([1, 2, 2, 2, 3], 2), lowerBound([1, 2, 3], 10), lowerBound([], 1));
}

main();
