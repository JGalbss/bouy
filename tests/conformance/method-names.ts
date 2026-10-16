// An object's own methods named `then`, `catch`, and `finally` are ordinary methods.

const handlers = {
  catch: (error: string): string => "handled " + error,
  then: (n: number): number => n + 1,
  finally: (): string => "done",
};

console.log(handlers.catch("x"), handlers.then(1), handlers.finally());
