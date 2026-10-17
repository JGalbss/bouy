// From the README of undici: request and fetch through a MockAgent, so no request leaves the
// process.
import { MockAgent, fetch, request } from "undici";

const agent = new MockAgent();
agent.disableNetConnect();
const pool = agent.get("http://api.example");
pool
  .intercept({ path: "/users/7", method: "GET" })
  .reply(200, { id: 7 }, { headers: { "content-type": "application/json" } });
pool.intercept({ path: "/echo", method: "POST" }).reply(201, ({ body }) => body);

const { statusCode, body } = await request("http://api.example/users/7", { dispatcher: agent });
console.log(statusCode, JSON.stringify(await body.json()));
const response = await fetch("http://api.example/echo", {
  method: "POST",
  body: "ping",
  dispatcher: agent,
});
console.log(response.status, await response.text());
try {
  await request("http://api.example/missing", { dispatcher: agent });
} catch (error) {
  console.log(error.name, error.code);
}
await agent.close();
