// From the README of lru-cache: a cache of two entries that evicts the least recently used.
import { LRUCache } from "lru-cache";

const cache = new LRUCache({ max: 2, dispose: (value, key) => console.log("dispose", key, value) });
cache.set("a", 1);
cache.set("b", 2);
cache.get("a");
cache.set("c", 3);
console.log(JSON.stringify([...cache.keys()]), cache.has("b"), cache.size);
console.log(
  cache.peek("a"),
  JSON.stringify(cache.dump().map(([key, entry]) => [key, entry.value])),
);
