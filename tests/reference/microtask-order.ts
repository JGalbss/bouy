// The classic ordering puzzle: sync, then microtasks in order, then timers.
console.log("1 sync");
setTimeout(() => console.log("8 timeout"), 0);
Promise.resolve()
  .then(() => console.log("3 then a"))
  .then(() => console.log("5 then b"));
queueMicrotask(() => console.log("4 microtask"));
(async () => {
  console.log("2 async body");
  await undefined;
  console.log("4b after await");
  await new Promise((r) => setTimeout(r, 0));
  console.log("9 after timer await");
})();
Promise.reject(new Error("boom"))
  .catch((e: Error) => console.log("3b caught", e.message))
  .finally(() => console.log("5b finally"));
const thenable = {
  then(resolve: (v: string) => void) {
    resolve("thenable");
  },
};
Promise.resolve(thenable).then((v) => console.log("6 adopted", v));
console.log("1b sync end");
