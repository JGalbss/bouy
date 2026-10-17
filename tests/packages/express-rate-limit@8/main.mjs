// From the README of express-rate-limit: limit an express app to two requests a window, on a
// local port.
import express from "express";
import { rateLimit } from "express-rate-limit";

const app = express();
app.use(
  rateLimit({ windowMs: 60_000, limit: 2, standardHeaders: "draft-8", legacyHeaders: false }),
);
app.get("/", (request, response) => response.send("ok"));
const server = await new Promise((resolve) => {
  const started = app.listen(0, "127.0.0.1", () => resolve(started));
});
for (let attempt = 1; attempt <= 3; attempt += 1) {
  const response = await fetch(`http://127.0.0.1:${server.address().port}/`);
  console.log(
    attempt,
    response.status,
    response.headers.get("ratelimit-policy"),
    await response.text(),
  );
}
server.close();
