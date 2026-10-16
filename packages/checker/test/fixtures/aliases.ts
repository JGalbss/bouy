import * as bouy from "bouy";
import { child as member, spawn as start, supervise } from "bouy";
import { pool } from "bouy/std";
import { spawn as fake } from "./lookalike.ts";
import { launch } from "./reexport.ts";

class Renamed {
  run(callback: () => void): void {}
}

class Namespaced {
  run(callback: () => void): void {}
}

class Supervised {
  run(callback: () => void): void {}
}

class Exported {
  run(callback: () => void): void {}
}

const Expression = class {
  run(callback: () => void): void {}
};

class Assigned {
  run(callback: () => void): void {}
}

class Destructured {
  run(callback: () => void): void {}
}

class Indexed {
  run(callback: () => void): void {}
}

class Pooled {
  run(callback: () => void): void {}
}

class Box<T> {
  put(value: T, callback: () => void): void {}
}

class Crate<T> {
  put(value: T, callback: () => void): void {}
}

class Ignored {
  run(callback: () => void): void {}
}

const assigned = start;
const { spawn: destructured } = bouy;

start(Renamed);
bouy.spawn(Namespaced);
supervise({
  strategy: "one-for-one",
  children: { worker: member(Supervised), crate: member(Crate<number>) },
});
launch(Exported);
start(Expression);
assigned(Assigned);
destructured(Destructured);
bouy["spawn"](Indexed);
pool(Pooled, 2);
start(Box<string>);
fake(Ignored);
