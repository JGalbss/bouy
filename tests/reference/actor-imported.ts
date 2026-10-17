// An actor whose class another module exports: its realm reads the class and the
// module state of that module.
import { spawn } from "bouy";
import { Counter } from "./modules/actor-counter.ts";

const one = spawn(Counter, { args: [1] });
const two = spawn(Counter, { args: [100] });
console.log(await one.add(), await one.add(), await two.add());
