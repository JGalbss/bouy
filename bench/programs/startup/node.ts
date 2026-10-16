// Startup, plain Node: start the runtime and print one line. No actors and no
// worker_threads. The harness measures the wall time from outside.
console.log(JSON.stringify({ hello: "world" }));
