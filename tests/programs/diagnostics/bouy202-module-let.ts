import { spawn } from "bouy";

let requests = 0;

class Api {
  handle(): number {
    requests++;
    return requests;
  }
}

const api = spawn(Api);
console.log(await api.handle());
