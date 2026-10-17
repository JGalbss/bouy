// From the README of body-parser: parse JSON and URL-encoded bodies on a plain node:http
// server.
import { createServer } from "node:http";
import bodyParser from "body-parser";

const json = bodyParser.json();
const form = bodyParser.urlencoded({ extended: false });
const server = createServer((request, response) => {
  const parse = request.headers["content-type"] === "application/json" ? json : form;
  parse(request, response, (error) => {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(error ? { error: error.type } : { body: request.body }));
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/`;
for (const [type, body] of [
  ["application/json", '{"a":[1,2]}'],
  ["application/x-www-form-urlencoded", "name=Ada&role=admin"],
  ["application/json", "{bad"],
]) {
  const response = await fetch(url, { method: "POST", headers: { "content-type": type }, body });
  console.log(response.status, await response.text());
}
server.close();
