import { spawn } from "bouy";

interface Note {
  readonly title: string;
}

class Repository<T> {
  add(item: T): void {}
}

class Notes extends Repository<Note> {}

class Callbacks extends Repository<() => void> {}

class Base {
  run(callback: () => void): void {}

  inherited(callback: () => void): void {}
}

class Overrides extends Base {
  override run(): void {}
}

spawn(Notes);
spawn(Callbacks);
spawn(Overrides);
