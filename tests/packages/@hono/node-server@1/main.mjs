// From the README of @hono/node-server: serve a Hono app on a local port and call it.
import { serve } from "@hono/node-server";
import { Hono } from "hono";

const app = new Hono();
app.get("/", (context) => context.text("Hello Node.js!"));
const server = await new Promise((resolve) => {
  const started = serve({ fetch: app.fetch, port: 0, hostname: "127.0.0.1" }, () =>
    resolve(started),
  );
});
const response = await fetch(`http://127.0.0.1:${server.address().port}/`);
console.log(response.status, await response.text());
server.close();
