// From the README of express: an app with routes, JSON, and a 404, on a local port.
import express from "express";

const app = express();
app.use(express.json());
app.get("/", (request, response) => response.send("Hello World"));
app.get("/users/:id", (request, response) => response.json({ id: request.params.id }));
app.post("/echo", (request, response) => response.status(201).json(request.body));
const server = await new Promise((resolve) => {
  const started = app.listen(0, "127.0.0.1", () => resolve(started));
});
const base = `http://127.0.0.1:${server.address().port}`;
for (const [path, init] of [
  ["/", {}],
  ["/users/7", {}],
  ["/echo", { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}' }],
  ["/missing", {}],
]) {
  const response = await fetch(base + path, init);
  console.log(
    response.status,
    response.headers.get("content-type"),
    (await response.text()).length,
  );
}
server.close();
