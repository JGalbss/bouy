// From the README of eventsource: listen to a server-sent event stream from a local server.
import { createServer } from "node:http";
import { EventSource } from "eventsource";

const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/event-stream" });
  response.end('data: first\n\nevent: update\ndata: {"n":2}\nid: 2\n\ndata: done\n\n');
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const source = new EventSource(`http://127.0.0.1:${server.address().port}/`);
const seen = [];
await new Promise((resolve) => {
  source.addEventListener("update", (event) =>
    seen.push(`update ${event.data} ${event.lastEventId}`),
  );
  source.onmessage = (event) => {
    seen.push(`message ${event.data}`);
    if (event.data === "done") resolve();
  };
});
source.close();
server.close();
console.log(seen.join(" | "));
console.log(source.readyState === EventSource.CLOSED);
