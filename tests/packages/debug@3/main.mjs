// From the README of debug: namespaces that DEBUG turns on, with output to a log function.
import createDebug from "debug";

createDebug.enable("app:*,-app:noisy");
const lines = [];
for (const namespace of ["app:server", "app:noisy", "other"]) {
  const log = createDebug(namespace);
  log.log = (...args) => lines.push(args.join(" "));
  log.useColors = false;
  console.log(namespace, log.enabled);
  log("listening on %d", 3000);
}
// Each line starts with a time, so the program prints only what the lines hold.
console.log(
  lines.length,
  lines.every((line) => line.includes("app:server listening on")),
);
console.log(createDebug.enabled("app:db"), createDebug.enabled("app:noisy"));
