export interface RateLimiterOptions {
  capacity: number;
  refillEveryMs: number;
  now?: () => number;
}

/**
 * Token bucket: `capacity` tokens, and one token back every `refillEveryMs`. A caller that
 * finds the bucket empty waits, and waiters are served in arrival order.
 */
export class TokenBucket {
  private tokens: number;
  private lastRefill: number;
  private readonly waiters: Array<() => void> = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  acquired = 0;
  throttled = 0;

  constructor(private readonly options: RateLimiterOptions) {
    this.tokens = options.capacity;
    this.lastRefill = this.now();
  }

  get available(): number {
    this.refill();
    return this.tokens;
  }

  get waiting(): number {
    return this.waiters.length;
  }

  acquire(): Promise<void> {
    this.refill();
    if (this.tokens > 0 && this.waiters.length === 0) {
      this.tokens--;
      this.acquired++;
      return Promise.resolve();
    }
    this.throttled++;
    return new Promise<void>((resolve) => {
      this.waiters.push(() => {
        this.acquired++;
        resolve();
      });
      this.scheduleDrain();
    });
  }

  async schedule<T>(task: () => Promise<T>): Promise<T> {
    await this.acquire();
    return task();
  }

  dispose(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private now(): number {
    return (this.options.now ?? Date.now)();
  }

  private refill(): void {
    const earned = Math.floor((this.now() - this.lastRefill) / this.options.refillEveryMs);
    if (earned <= 0) return;
    this.tokens = Math.min(this.options.capacity, this.tokens + earned);
    this.lastRefill += earned * this.options.refillEveryMs;
  }

  private scheduleDrain(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.refill();
      while (this.tokens > 0 && this.waiters.length > 0) {
        this.tokens--;
        this.waiters.shift()!();
      }
      if (this.waiters.length > 0) this.scheduleDrain();
    }, this.options.refillEveryMs);
  }
}
