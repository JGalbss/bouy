import { spawn } from "bouy";

class Writer {
  async save(item?: string): Promise<void> {}

  async write(): Promise<void> {
    this.save();
    this.save().then(() => undefined);
    await this.save();
    void this.save();
    const pending = this.save();
    await pending;
  }

  batch(items: ReadonlyArray<string>): Promise<void> {
    items.forEach(() => {
      this.save();
    });
    return this.save();
  }

  concise(items: ReadonlyArray<string>): void {
    items.forEach((item) => this.save(item));
    setTimeout(() => this.save(), 10);
  }

  async lists(items: ReadonlyArray<string>): Promise<void> {
    items.map(async (item) => this.save(item));
    await [this.save("first"), this.save("second")];
    await Promise.all([this.save("third")]);
  }

  hidden(): void {
    this.save() as unknown;
  }
}

spawn(Writer);
