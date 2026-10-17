// From the README of hono: an app with routes, a parameter, JSON, and middleware, called
// with app.request, so no server starts.
import { Hono } from "hono";

const app = new Hono();
app.use(async (context, next) => {
  await next();
  context.header("x-powered-by", "hono");
});
app.get("/", (context) => context.text("Hello Hono!"));
app.get("/users/:id", (context) => context.json({ id: context.req.param("id") }));
app.post("/echo", async (context) => context.json(await context.req.json(), 201));

for (const request of [
  new Request("http://localhost/"),
  new Request("http://localhost/users/7"),
  new Request("http://localhost/echo", { method: "POST", body: '{"a":1}' }),
  new Request("http://localhost/missing"),
]) {
  const response = await app.request(request);
  console.log(response.status, response.headers.get("x-powered-by"), await response.text());
}
