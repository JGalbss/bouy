import { spawn } from "bouy";

class Clock {
  tick(): string {
    return "tick";
  }
}

const clock = spawn(Clock);
setTimeout(() => console.log(clock), 100);
