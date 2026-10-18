// An MCP server on a local HTTP port and a client that talks to it over Streamable HTTP.
import { createServer as createHttpServer } from "node:http";
import type { AddressInfo } from "node:net";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createServer } from "./lib/server.ts";
import { exercise } from "./lib/exercise.ts";

// Stateless: each request gets a fresh server and transport.
const http = createHttpServer((request, response) => {
  const server = createServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  response.on("close", () => {
    void transport.close();
    void server.close();
  });
  void server.connect(transport).then(() => transport.handleRequest(request, response));
});
await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
const { port } = http.address() as AddressInfo;

const client = new Client({ name: "buoy-test-client", version: "1.0.0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
await exercise(client);
await client.close();
await new Promise((resolve) => http.close(resolve));
