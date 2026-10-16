export default class Shapes {
  handler = async (items: string[]): Promise<number> => {
    let count = 0;
    for (const item of items) count += item.length;
    return count;
  };

  static {
    for (let index = 0; index < 2; index += 1) Shapes.ready = index;
  }

  static ready = 0;

  async labeled(rows: number[][]): Promise<number> {
    let total = 0;
    outer: for (const row of rows) {
      for (const cell of row) {
        if (cell < 0) continue outer;
        total += cell;
      }
    }
    return total;
  }

  async drain(source: AsyncIterable<number>): Promise<number> {
    let sum = 0;
    for await (const value of source) sum += value;
    do {
      sum -= 1;
    } while (sum > 100);
    return sum;
  }

  *syncGenerator(): Generator<number> {
    for (let index = 0; index < 3; index += 1) yield index;
  }

  async *asyncGenerator(): AsyncGenerator<number> {
    for (let index = 0; index < 3; index += 1) yield index;
  }

  async withHelper(values: number[]): Promise<number> {
    const square = (value: number): number => {
      let result = 0;
      for (let step = 0; step < value; step += 1) result += value;
      return result;
    };
    return values.map(square).reduce((first, second) => first + second, 0);
  }
}

for (let index = 0; index < 3; index += 1) console.log(index);
