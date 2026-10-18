// A standard descriptor that the program closed gives no handle, so
// process.stdin is an empty Readable, as for a descriptor that libuv
// cannot guess, and a second close fails with EBADF.
import { closeSync } from "node:fs";

closeSync(0);
console.log(process.stdin.constructor.name);
process.stdin.on("end", () => console.log("end"));
process.stdin.resume();
try {
  closeSync(0);
} catch (error) {
  console.log((error as NodeJS.ErrnoException).code);
}
