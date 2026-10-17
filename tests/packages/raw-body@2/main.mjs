// From the README of raw-body: read a whole stream into a string, with a limit.
import { Readable } from "node:stream";
import getRawBody from "raw-body";

const body = await getRawBody(Readable.from([Buffer.from("hello "), Buffer.from("world")]), {
  length: 11,
  limit: "1kb",
  encoding: "utf8",
});
console.log(JSON.stringify(body));
try {
  await getRawBody(Readable.from([Buffer.from("too long")]), { limit: 3 });
} catch (error) {
  console.log(error.type, error.status);
}
