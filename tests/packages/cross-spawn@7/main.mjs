// From the README of cross-spawn: run a command synchronously and asynchronously.
import spawn from "cross-spawn";

const result = spawn.sync("echo", ["hello", "from", "cross-spawn"], { encoding: "utf8" });
console.log(result.status, JSON.stringify(result.stdout));
const child = spawn("sh", ["-c", "echo async; exit 3"], { stdio: ["ignore", "pipe", "ignore"] });
let output = "";
child.stdout.on("data", (data) => (output += data));
const code = await new Promise((resolve) => child.on("close", resolve));
console.log(code, JSON.stringify(output));
