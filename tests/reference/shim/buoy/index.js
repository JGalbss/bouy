// The Node oracle for the actor programs of tests/reference: an actor is an instance
// whose calls run one turn at a time, with arguments and results copied by
// structuredClone, as `buoy run --semantics reference` runs them on BEAM.
export function spawn(Class, options = {}) {
  const instance = new Class(...structuredClone(options.args ?? []));
  let turn = Promise.resolve();
  return new Proxy(
    {},
    {
      get(_target, method) {
        return (...args) => {
          const copied = structuredClone(args);
          const result = turn.then(() => instance[method](...copied)).then(structuredClone);
          turn = result.catch(() => {});
          return result;
        };
      },
    },
  );
}

export function stop() {}
