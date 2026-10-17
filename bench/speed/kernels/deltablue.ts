// DeltaBlue: the incremental constraint solver of Freeman-Benson, Maloney, and Borning,
// ported from the Octane suite (v8/benchmarks deltablue.js) to TypeScript classes. Arrays
// replace Octane's OrderedCollection. One iteration runs chainTest(100) and
// projectionTest(100) `size` times. Usage: deltablue.ts [warmup] [runs] [size]

class Strength {
  static readonly REQUIRED = new Strength(0, "required");
  static readonly STRONG_PREFERRED = new Strength(1, "strongPreferred");
  static readonly PREFERRED = new Strength(2, "preferred");
  static readonly STRONG_DEFAULT = new Strength(3, "strongDefault");
  static readonly NORMAL = new Strength(4, "normal");
  static readonly WEAK_DEFAULT = new Strength(5, "weakDefault");
  static readonly WEAKEST = new Strength(6, "weakest");

  readonly strengthValue: number;
  readonly name: string;

  constructor(strengthValue: number, name: string) {
    this.strengthValue = strengthValue;
    this.name = name;
  }

  static stronger(s1: Strength, s2: Strength): boolean {
    return s1.strengthValue < s2.strengthValue;
  }

  static weaker(s1: Strength, s2: Strength): boolean {
    return s1.strengthValue > s2.strengthValue;
  }

  static weakestOf(s1: Strength, s2: Strength): Strength {
    return Strength.weaker(s1, s2) ? s1 : s2;
  }

  // Octane's table: REQUIRED steps to WEAKEST, so incrementalRemove makes one pass.
  nextWeaker(): Strength {
    switch (this.strengthValue) {
      case 0:
        return Strength.WEAKEST;
      case 1:
        return Strength.WEAK_DEFAULT;
      case 2:
        return Strength.NORMAL;
      case 3:
        return Strength.STRONG_DEFAULT;
      case 4:
        return Strength.PREFERRED;
      default:
        return Strength.REQUIRED;
    }
  }
}

const NONE = 0;
const FORWARD = 1;
const BACKWARD = -1;

abstract class Constraint {
  strength: Strength;

  constructor(strength: Strength) {
    this.strength = strength;
  }

  abstract addToGraph(): void;
  abstract chooseMethod(mark: number): void;
  abstract isSatisfied(): boolean;
  abstract markInputs(mark: number): void;
  abstract output(): Variable;
  abstract recalculate(): void;
  abstract markUnsatisfied(): void;
  abstract inputsKnown(mark: number): boolean;
  abstract removeFromGraph(): void;
  abstract execute(): void;

  addConstraint(): void {
    this.addToGraph();
    planner.incrementalAdd(this);
  }

  satisfy(mark: number): Constraint | null {
    this.chooseMethod(mark);
    if (!this.isSatisfied()) {
      if (this.strength === Strength.REQUIRED) throw new Error("required constraint unsatisfied");
      return null;
    }
    this.markInputs(mark);
    const out = this.output();
    const overridden = out.determinedBy;
    if (overridden !== null) overridden.markUnsatisfied();
    out.determinedBy = this;
    if (!planner.addPropagate(this, mark)) throw new Error("cycle encountered");
    out.mark = mark;
    return overridden;
  }

  destroyConstraint(): void {
    if (this.isSatisfied()) planner.incrementalRemove(this);
    else this.removeFromGraph();
  }

  isInput(): boolean {
    return false;
  }
}

abstract class UnaryConstraint extends Constraint {
  myOutput: Variable;
  satisfied = false;

  constructor(v: Variable, strength: Strength) {
    super(strength);
    this.myOutput = v;
    this.addConstraint();
  }

  addToGraph(): void {
    this.myOutput.addConstraint(this);
    this.satisfied = false;
  }

  chooseMethod(mark: number): void {
    this.satisfied =
      this.myOutput.mark !== mark && Strength.stronger(this.strength, this.myOutput.walkStrength);
  }

  isSatisfied(): boolean {
    return this.satisfied;
  }

  markInputs(_mark: number): void {}

  output(): Variable {
    return this.myOutput;
  }

  recalculate(): void {
    this.myOutput.walkStrength = this.strength;
    this.myOutput.stay = !this.isInput();
    if (this.myOutput.stay) this.execute();
  }

  markUnsatisfied(): void {
    this.satisfied = false;
  }

  inputsKnown(_mark: number): boolean {
    return true;
  }

  removeFromGraph(): void {
    this.myOutput.removeConstraint(this);
    this.satisfied = false;
  }
}

class StayConstraint extends UnaryConstraint {
  execute(): void {}
}

class EditConstraint extends UnaryConstraint {
  override isInput(): boolean {
    return true;
  }

  execute(): void {}
}

abstract class BinaryConstraint extends Constraint {
  v1: Variable;
  v2: Variable;
  direction = NONE;

  constructor(var1: Variable, var2: Variable, strength: Strength) {
    super(strength);
    this.v1 = var1;
    this.v2 = var2;
  }

  chooseMethod(mark: number): void {
    if (this.v1.mark === mark) {
      this.direction =
        this.v2.mark !== mark && Strength.stronger(this.strength, this.v2.walkStrength)
          ? FORWARD
          : NONE;
    }
    if (this.v2.mark === mark) {
      this.direction =
        this.v1.mark !== mark && Strength.stronger(this.strength, this.v1.walkStrength)
          ? BACKWARD
          : NONE;
    }
    if (Strength.weaker(this.v1.walkStrength, this.v2.walkStrength)) {
      this.direction = Strength.stronger(this.strength, this.v1.walkStrength) ? BACKWARD : NONE;
    } else {
      this.direction = Strength.stronger(this.strength, this.v2.walkStrength) ? FORWARD : BACKWARD;
    }
  }

  addToGraph(): void {
    this.v1.addConstraint(this);
    this.v2.addConstraint(this);
    this.direction = NONE;
  }

  isSatisfied(): boolean {
    return this.direction !== NONE;
  }

  markInputs(mark: number): void {
    this.input().mark = mark;
  }

  input(): Variable {
    return this.direction === FORWARD ? this.v1 : this.v2;
  }

  output(): Variable {
    return this.direction === FORWARD ? this.v2 : this.v1;
  }

  recalculate(): void {
    const input = this.input();
    const out = this.output();
    out.walkStrength = Strength.weakestOf(this.strength, input.walkStrength);
    out.stay = input.stay;
    if (out.stay) this.execute();
  }

  markUnsatisfied(): void {
    this.direction = NONE;
  }

  inputsKnown(mark: number): boolean {
    const input = this.input();
    return input.mark === mark || input.stay || input.determinedBy === null;
  }

  removeFromGraph(): void {
    this.v1.removeConstraint(this);
    this.v2.removeConstraint(this);
    this.direction = NONE;
  }
}

class ScaleConstraint extends BinaryConstraint {
  scale: Variable;
  offset: Variable;

  constructor(
    src: Variable,
    scale: Variable,
    offset: Variable,
    dest: Variable,
    strength: Strength,
  ) {
    super(src, dest, strength);
    this.scale = scale;
    this.offset = offset;
    this.addConstraint();
  }

  override addToGraph(): void {
    super.addToGraph();
    this.scale.addConstraint(this);
    this.offset.addConstraint(this);
  }

  override removeFromGraph(): void {
    super.removeFromGraph();
    this.scale.removeConstraint(this);
    this.offset.removeConstraint(this);
  }

  override markInputs(mark: number): void {
    super.markInputs(mark);
    this.scale.mark = mark;
    this.offset.mark = mark;
  }

  execute(): void {
    if (this.direction === FORWARD) {
      this.v2.value = this.v1.value * this.scale.value + this.offset.value;
    } else {
      this.v1.value = (this.v2.value - this.offset.value) / this.scale.value;
    }
  }

  override recalculate(): void {
    const input = this.input();
    const out = this.output();
    out.walkStrength = Strength.weakestOf(this.strength, input.walkStrength);
    out.stay = input.stay && this.scale.stay && this.offset.stay;
    if (out.stay) this.execute();
  }
}

class EqualityConstraint extends BinaryConstraint {
  constructor(var1: Variable, var2: Variable, strength: Strength) {
    super(var1, var2, strength);
    this.addConstraint();
  }

  execute(): void {
    this.output().value = this.input().value;
  }
}

class Variable {
  value: number;
  constraints: Constraint[] = [];
  determinedBy: Constraint | null = null;
  mark = 0;
  walkStrength = Strength.WEAKEST;
  stay = true;
  name: string;

  constructor(name: string, initialValue = 0) {
    this.value = initialValue;
    this.name = name;
  }

  addConstraint(c: Constraint): void {
    this.constraints.push(c);
  }

  removeConstraint(c: Constraint): void {
    this.constraints = this.constraints.filter((each) => each !== c);
    if (this.determinedBy === c) this.determinedBy = null;
  }
}

class Plan {
  constraints: Constraint[] = [];

  addConstraint(c: Constraint): void {
    this.constraints.push(c);
  }

  execute(): void {
    for (const c of this.constraints) c.execute();
  }
}

class Planner {
  currentMark = 0;

  incrementalAdd(c: Constraint): void {
    const mark = this.newMark();
    let overridden = c.satisfy(mark);
    while (overridden !== null) overridden = overridden.satisfy(mark);
  }

  incrementalRemove(c: Constraint): void {
    const out = c.output();
    c.markUnsatisfied();
    c.removeFromGraph();
    const unsatisfied = this.removePropagateFrom(out);
    let strength = Strength.REQUIRED;
    do {
      for (const u of unsatisfied) {
        if (u.strength === strength) this.incrementalAdd(u);
      }
      strength = strength.nextWeaker();
    } while (strength !== Strength.WEAKEST);
  }

  newMark(): number {
    return ++this.currentMark;
  }

  makePlan(sources: Constraint[]): Plan {
    const mark = this.newMark();
    const plan = new Plan();
    const todo = sources;
    for (let c = todo.shift(); c !== undefined; c = todo.shift()) {
      if (c.output().mark !== mark && c.inputsKnown(mark)) {
        plan.addConstraint(c);
        c.output().mark = mark;
        this.addConstraintsConsumingTo(c.output(), todo);
      }
    }
    return plan;
  }

  extractPlanFromConstraints(constraints: Constraint[]): Plan {
    const sources = constraints.filter((c) => c.isInput() && c.isSatisfied());
    return this.makePlan(sources);
  }

  addPropagate(c: Constraint, mark: number): boolean {
    const todo = [c];
    for (let d = todo.shift(); d !== undefined; d = todo.shift()) {
      if (d.output().mark === mark) {
        this.incrementalRemove(c);
        return false;
      }
      d.recalculate();
      this.addConstraintsConsumingTo(d.output(), todo);
    }
    return true;
  }

  removePropagateFrom(out: Variable): Constraint[] {
    out.determinedBy = null;
    out.walkStrength = Strength.WEAKEST;
    out.stay = true;
    const unsatisfied: Constraint[] = [];
    const todo = [out];
    for (let v = todo.shift(); v !== undefined; v = todo.shift()) {
      for (const c of v.constraints) {
        if (!c.isSatisfied()) unsatisfied.push(c);
      }
      const determining = v.determinedBy;
      for (const next of v.constraints) {
        if (next !== determining && next.isSatisfied()) {
          next.recalculate();
          todo.push(next.output());
        }
      }
    }
    return unsatisfied;
  }

  addConstraintsConsumingTo(v: Variable, coll: Constraint[]): void {
    const determining = v.determinedBy;
    for (const c of v.constraints) {
      if (c !== determining && c.isSatisfied()) coll.push(c);
    }
  }
}

let planner = new Planner();

function chainTest(n: number): number {
  planner = new Planner();
  let prev: Variable | null = null;
  let first: Variable | null = null;
  let last: Variable | null = null;
  for (let i = 0; i <= n; i++) {
    const v = new Variable(`v${i}`);
    if (prev !== null) new EqualityConstraint(prev, v, Strength.REQUIRED);
    if (i === 0) first = v;
    if (i === n) last = v;
    prev = v;
  }
  if (first === null || last === null) throw new Error("empty chain");
  new StayConstraint(last, Strength.STRONG_DEFAULT);
  const edit = new EditConstraint(first, Strength.PREFERRED);
  const plan = planner.extractPlanFromConstraints([edit]);
  for (let i = 0; i < 100; i++) {
    first.value = i;
    plan.execute();
    if (last.value !== i) throw new Error("chain test failed");
  }
  return last.value;
}

function change(v: Variable, newValue: number): void {
  const edit = new EditConstraint(v, Strength.PREFERRED);
  const plan = planner.extractPlanFromConstraints([edit]);
  for (let i = 0; i < 10; i++) {
    v.value = newValue;
    plan.execute();
  }
  edit.destroyConstraint();
}

function projectionTest(n: number): number {
  planner = new Planner();
  const scale = new Variable("scale", 10);
  const offset = new Variable("offset", 1000);
  let src = scale;
  let dst = offset;
  const dests: Variable[] = [];
  for (let i = 0; i < n; i++) {
    src = new Variable(`src${i}`, i);
    dst = new Variable(`dst${i}`, i);
    dests.push(dst);
    new StayConstraint(src, Strength.NORMAL);
    new ScaleConstraint(src, scale, offset, dst, Strength.REQUIRED);
  }
  change(src, 17);
  if (dst.value !== 1170) throw new Error("projection 1 failed");
  change(dst, 1050);
  if (src.value !== 5) throw new Error("projection 2 failed");
  change(scale, 5);
  for (let i = 0; i < n - 1; i++) {
    if (dests[i]?.value !== i * 5 + 1000) throw new Error("projection 3 failed");
  }
  change(offset, 2000);
  for (let i = 0; i < n - 1; i++) {
    if (dests[i]?.value !== i * 5 + 2000) throw new Error("projection 4 failed");
  }
  return dst.value;
}

function iteration(size: number): number {
  let check = 0;
  for (let i = 0; i < size; i++) check += chainTest(100) + projectionTest(100);
  return check;
}

function bench(name: string, defaultSize: number, work: (size: number) => number): void {
  // The reference engine has neither `process` nor `performance` yet.
  const args = typeof process === "undefined" ? [] : process.argv.slice(2).map(Number);
  const now = typeof performance === "undefined" ? Date.now : () => performance.now();
  const warmup = args[0] ?? 3;
  const runs = args[1] ?? 5;
  const size = args[2] ?? defaultSize;
  const times: number[] = [];
  let check = 0;
  for (let i = 0; i < warmup + runs; i++) {
    const start = now();
    check = work(size);
    const elapsed = now() - start;
    if (i >= warmup) times.push(elapsed);
  }
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)] ?? 0;
  console.log(JSON.stringify({ kernel: name, size, median_ms: median, times_ms: times, check }));
}

bench("deltablue", 100, iteration);
