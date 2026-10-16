import { spawn } from "bouy";

class Deferred {
  then(value: string): string {
    return value;
  }
}

class Computed {
  ["then"](value: string): string {
    return value;
  }
}

class Overloaded {
  then(value: string): string;
  then(value: number): number;
  then(value: string | number): string | number {
    return value;
  }
}

class Settled {
  thenable(): boolean {
    return false;
  }

  #then(): void {}

  static then(): void {}

  get then(): number {
    return 1;
  }
}

spawn(Deferred);
spawn(Computed);
spawn(Overloaded);
spawn(Settled);
