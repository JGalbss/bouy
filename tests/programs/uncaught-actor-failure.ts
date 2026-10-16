import { spawn } from "bouy";

class Worker {
  fail(): void {
    throw new RangeError("out of range");
  }
}

const worker = spawn(Worker, { name: "worker" });
console.log("before the call");
await worker.fail();
console.log("this line never prints");
