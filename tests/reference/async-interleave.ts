// Two async functions await each other's promises and interleave.
const log: string[] = [];

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const ping = deferred<number>();
const pong = deferred<number>();

async function left(): Promise<string> {
  log.push("left start");
  ping.resolve(1);
  const got = await pong.promise;
  log.push(`left got ${got}`);
  await null;
  log.push("left end");
  return "L";
}

async function right(): Promise<string> {
  log.push("right start");
  const got = await ping.promise;
  log.push(`right got ${got}`);
  pong.resolve(got + 1);
  log.push("right end");
  return "R";
}

const both = Promise.all([left(), right()]);
log.push("sync end");
both.then((values) => {
  console.log(log.join("\n"));
  console.log(values);
});
