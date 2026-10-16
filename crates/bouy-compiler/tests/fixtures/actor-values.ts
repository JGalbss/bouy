export class Builder {
  parts: string[] = [];
  #secret = "pin";
  #subs = new Map<string, number[]>();

  constructor(init: { parts?: string[] }) {
    Object.assign(this, init);
  }

  add(part: string): this {
    this.parts.push(part);
    return this;
  }

  label(n: number): string {
    return `#${n}`;
  }

  build(op: string): string {
    this.add("a").add("b");
    this.#subs.get("topic")?.push(1);
    const labels = [1, 2].map(this.label);
    this[op]("c");
    return `${this.#secret}:${labels.join(",")}:${this.parts.join(",")}`;
  }
}
