// From the README of lru-cache 5: a cache of two entries that evicts the least recently used.
import LRU from "lru-cache";

const cache = new LRU({ max: 2, dispose: (key, value) => console.log("dispose", key, value) });
cache.set("a", 1);
cache.set("b", 2);
cache.get("a");
cache.set("c", 3);
console.log(JSON.stringify(cache.keys()), cache.has("b"), cache.length);
console.log(cache.peek("a"), JSON.stringify(cache.dump().map((entry) => [entry.k, entry.v])));
