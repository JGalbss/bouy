export function later(): number {
  const read = (): number => x * 2;
  const x = 21;
  return read();
}

export function ownInitializer(): number {
  const api = { one: (): number => 1, two: (): number => api.one() + 1 };
  return api.two();
}

export function tooEarly(): number {
  const total = describe();
  const base = 2;
  function describe(): number {
    return base;
  }
  return total;
}

export function head(items: number[]): number {
  const state = { last: 0 };
  const scan = (): void => {
    for (state.last of items) {
    }
  };
  scan();
  return state.last;
}
