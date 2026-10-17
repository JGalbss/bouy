interface Entry<V> {
  value: V;
  expiresAt: number;
}

export interface CacheStats {
  hits: number;
  misses: number;
  evictions: number;
  size: number;
}

/**
 * A TTL cache with LRU eviction. A Map iterates in insertion order, so re-inserting a key on
 * every hit keeps the least recently used key first.
 */
export class TtlCache<K, V> implements Iterable<[K, V]> {
  static readonly DEFAULT_TTL_MS = 60_000;
  static #instances = 0;

  readonly name: string;
  readonly #entries = new Map<K, Entry<V>>();
  #hits = 0;
  #misses = 0;
  #evictions = 0;

  constructor(
    name: string,
    private readonly ttlMs = TtlCache.DEFAULT_TTL_MS,
    private readonly maxEntries = 500,
    private readonly now: () => number = Date.now,
  ) {
    this.name = name;
    TtlCache.#instances++;
  }

  static get instances(): number {
    return TtlCache.#instances;
  }

  get size(): number {
    return this.#entries.size;
  }

  get stats(): CacheStats {
    return { hits: this.#hits, misses: this.#misses, evictions: this.#evictions, size: this.size };
  }

  get hitRate(): number {
    const lookups = this.#hits + this.#misses;
    return lookups === 0 ? 0 : this.#hits / lookups;
  }

  get(key: K): V | undefined {
    const entry = this.#entries.get(key);
    if (!entry || entry.expiresAt <= this.now()) {
      if (entry) this.#entries.delete(key);
      this.#misses++;
      return undefined;
    }
    this.#entries.delete(key);
    this.#entries.set(key, entry);
    this.#hits++;
    return entry.value;
  }

  set(key: K, value: V): this {
    this.#entries.delete(key);
    this.#entries.set(key, { value, expiresAt: this.now() + this.ttlMs });
    while (this.#entries.size > this.maxEntries) {
      const oldest = this.#entries.keys().next().value as K;
      this.#entries.delete(oldest);
      this.#evictions++;
    }
    return this;
  }

  async getOrLoad(key: K, load: (key: K) => Promise<V>): Promise<V> {
    const cached = this.get(key);
    if (cached !== undefined) return cached;
    const value = await load(key);
    this.set(key, value);
    return value;
  }

  clear(): void {
    this.#entries.clear();
  }

  *[Symbol.iterator](): IterableIterator<[K, V]> {
    const now = this.now();
    for (const [key, entry] of this.#entries) {
      if (entry.expiresAt > now) yield [key, entry.value];
    }
  }
}

/** Caches the result of `fn` for each argument, for the life of the process. */
export function memoize<A, R>(fn: (arg: A) => R): (arg: A) => R {
  const cache = new Map<A, R>();
  return (arg: A): R => {
    if (cache.has(arg)) return cache.get(arg) as R;
    const result = fn(arg);
    cache.set(arg, result);
    return result;
  };
}
