import { sleep, spawn } from "bouy";

class Checker {
  check(url: string, delay: number): string {
    sleep(delay);
    if (url.startsWith("down.")) {
      throw new Error(`cannot reach ${url}`);
    }
    return `${url} is up`;
  }
}

async function main(): Promise<void> {
  const checkers = [spawn(Checker), spawn(Checker), spawn(Checker)];
  const urls = ["a.example", "down.example", "c.example"];
  const results = await Promise.allSettled(urls.map((url, i) => checkers[i].check(url, 0)));
  for (const result of results) {
    console.log(result.status === "fulfilled" ? result.value : result.reason.message);
  }
  const mirrors = ["slow.example", "fast.example", "medium.example"];
  const delays = [300, 10, 200];
  const fastest = await Promise.race(mirrors.map((url, i) => checkers[i].check(url, delays[i])));
  console.log(`the fastest mirror: ${fastest}`);
}

await main();
