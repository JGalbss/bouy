// A timer is a Timeout also before any built-in module loads, and an unref'd one does
// not keep the program alive, even when it comes due before the program ends.
const timer = setTimeout(() => console.log("never"), 1);
console.log(timer.hasRef(), timer.unref() === timer, timer.hasRef());
const end = Date.now() + 50;
while (Date.now() < end) {}
console.log("done");
