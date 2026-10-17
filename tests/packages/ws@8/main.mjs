// From the README of ws: a server on a local port that echoes each message, and a client.
import { WebSocket, WebSocketServer } from "ws";

const server = new WebSocketServer({ port: 0, host: "127.0.0.1" });
await new Promise((resolve) => server.on("listening", resolve));
server.on("connection", (socket) => {
  socket.on("message", (data, isBinary) => socket.send(isBinary ? data : `echo: ${data}`));
});
const client = new WebSocket(`ws://127.0.0.1:${server.address().port}`);
await new Promise((resolve) => client.on("open", resolve));
const replies = [];
const done = new Promise((resolve) =>
  client.on("message", (data, isBinary) => {
    replies.push(isBinary ? `binary ${data.length}` : String(data));
    if (replies.length === 2) resolve();
  }),
);
client.send("hello");
client.send(Buffer.from([1, 2, 3]));
await done;
console.log(replies.join(" | "));
client.close();
await new Promise((resolve) => client.on("close", (code) => resolve(console.log("closed", code))));
server.close();
