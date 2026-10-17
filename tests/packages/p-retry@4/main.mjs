// From the README of p-retry: retry a failing function with no delay, then give up on an
// abort error.
import pRetry, { AbortError } from "p-retry";

let attempts = 0;
const value = await pRetry(
  async () => {
    attempts += 1;
    if (attempts < 3) throw new Error(`attempt ${attempts} failed`);
    return "done";
  },
  {
    retries: 5,
    minTimeout: 0,
    maxTimeout: 0,
    onFailedAttempt: (error) => console.log("failed", error.attemptNumber ?? error.attempt?.number),
  },
);
console.log(value, attempts);
try {
  await pRetry(() => Promise.reject(new AbortError("stop")), { retries: 5, minTimeout: 0 });
} catch (error) {
  console.log(error.name, error.message);
}
