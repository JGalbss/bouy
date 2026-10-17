// Static fields, static methods, and static blocks.
class Registry {
  static count = 0;
  static readonly names: string[] = [];
  static {
    Registry.names.push("boot");
  }
  id: number;
  constructor(name: string) {
    Registry.count++;
    this.id = Registry.count;
    Registry.names.push(name);
  }
  static create(name: string): Registry {
    return new Registry(name);
  }
  static summary(): string {
    return `${this.count}: ${this.names.join(",")}`;
  }
}

class Sub extends Registry {
  static kind = "sub";
}

Registry.create("a");
new Registry("b");
console.log(Registry.summary(), Registry.create("c").id);
console.log(Sub.kind, Sub.count, Sub.summary());
