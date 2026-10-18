// Prints one line, then waits, so that a test can stop it with a signal.
import { sleep } from "buoy";

console.log("start");
sleep(30000);
console.log("end");
