import { EventEmitter } from "node:events";
import { spawn } from "bouy";

const bell = new EventEmitter();

const localOnly = new EventEmitter();

class Listener {
  #heard = 0;

  listen(): void {
    bell.on("ring", () => {
      this.#heard += 1;
    });
  }

  heard(): number {
    return this.#heard;
  }
}

class Ringer {
  ring(): void {
    bell.emit("ring");
  }
}

class Quiet {
  count(): number {
    return 1;
  }
}

localOnly.emit("ignored");

spawn(Listener);
spawn(Ringer);
spawn(Quiet);
