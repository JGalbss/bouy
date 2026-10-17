// From the README of langsmith: trace a function with traceable. LANGSMITH_TRACING is not
// set, so nothing leaves the process.
import { traceable } from "langsmith/traceable";

const add = traceable(async (a, b) => a + b, { name: "add", run_type: "tool" });
const pipeline = traceable(async (input) => `sum: ${await add(input.a, input.b)}`, {
  name: "pipeline",
});
console.log(await pipeline({ a: 2, b: 3 }));
console.log(typeof add, add.name);
