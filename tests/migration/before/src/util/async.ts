import { TimeoutError } from "../errors.ts";

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
}

export function defer<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Rejects with a TimeoutError when `promise` does not settle within `ms`. */
export function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  operation = "operation",
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimeoutError(operation, ms)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

export interface RetryOptions {
  retries: number;
  baseDelayMs: number;
  maxDelayMs?: number;
  shouldRetry?: (error: unknown, attempt: number) => boolean;
  onRetry?: (error: unknown, attempt: number, delayMs: number) => void;
}

/**
 * Runs `task` until it succeeds, at most `retries + 1` times, with exponential backoff and
 * jitter between attempts.
 */
export function retry<T>(task: (attempt: number) => Promise<T>, options: RetryOptions): Promise<T> {
  const { retries, baseDelayMs, maxDelayMs = 1_000, shouldRetry = () => true, onRetry } = options;

  const attempt = (n: number): Promise<T> =>
    task(n).catch((error: unknown) => {
      if (n > retries || !shouldRetry(error, n)) throw error;
      const ceiling = Math.min(maxDelayMs, baseDelayMs * 2 ** (n - 1));
      const delay = Math.round(ceiling / 2 + Math.random() * (ceiling / 2));
      onRetry?.(error, n, delay);
      return sleep(delay).then(() => attempt(n + 1));
    });

  return attempt(1);
}
