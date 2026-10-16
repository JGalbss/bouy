process.send?.("ready");
process.on("message", (message) => process.send?.(message));
