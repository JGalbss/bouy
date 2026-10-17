// An event emitter: listeners in a Map of arrays, closures that unsubscribe themselves.
type Listener = (payload: string) => void;
class Emitter {
  #listeners = new Map<string, Listener[]>();
  on(event: string, listener: Listener): () => void {
    const list = this.#listeners.get(event) ?? [];
    list.push(listener);
    this.#listeners.set(event, list);
    return () => {
      const current = this.#listeners.get(event) ?? [];
      this.#listeners.set(
        event,
        current.filter((l) => l !== listener),
      );
    };
  }
  emit(event: string, payload: string): number {
    const list = this.#listeners.get(event) ?? [];
    for (const l of [...list]) l(payload);
    return list.length;
  }
}

const e = new Emitter();
const received: string[] = [];
const off = e.on("msg", (p) => received.push(`a:${p}`));
e.on("msg", (p) => received.push(`b:${p}`));
let onceOff: () => void = () => {};
onceOff = e.on("msg", (p) => {
  received.push(`once:${p}`);
  onceOff();
});
console.log(e.emit("msg", "1"));
off();
console.log(e.emit("msg", "2"), e.emit("none", "x"));
console.log(received);
