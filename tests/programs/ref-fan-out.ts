import { spawn, type Ref } from "buoy";

class Inventory {
  #stock = new Map<string, number>();

  add(item: string): number {
    const count = (this.#stock.get(item) ?? 0) + 1;
    this.#stock.set(item, count);
    return count;
  }

  delete(item: string): boolean {
    return this.#stock.delete(item);
  }

  count(item: string): number {
    return this.#stock.get(item) ?? 0;
  }
}

class Warehouse {
  // The type Ref tells the compiler that `add` is an actor call, not a Set mutation.
  #inventory: Ref<Inventory>;

  constructor(inventory: Ref<Inventory>) {
    this.#inventory = inventory;
  }

  receive(items: string[]): Promise<number[]> {
    return Promise.all(items.map((item) => this.#inventory.add(item)));
  }
}

async function restock(inventory: Ref<Inventory>, items: string[]): Promise<number[]> {
  return Promise.all(items.map((item) => inventory.add(item)));
}

async function main(): Promise<void> {
  const inventory = spawn(Inventory);
  const warehouse = spawn(Warehouse, { args: [inventory] });
  console.log(await warehouse.receive(["bolt", "nut", "washer"]));
  console.log(await restock(inventory, ["bolt", "screw"]));
  console.log(await inventory.delete("nut"), await inventory.count("bolt"));
}

await main();
