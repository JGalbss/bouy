// From the README of @modelcontextprotocol/sdk: a server with a tool, and a client that
// lists and calls it over a linked pair of in-memory transports.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const server = new McpServer({ name: "demo", version: "1.0.0" });
server.registerTool(
  "add",
  { description: "Add two numbers", inputSchema: { a: z.number(), b: z.number() } },
  async ({ a, b }) => ({ content: [{ type: "text", text: String(a + b) }] }),
);
const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
const client = new Client({ name: "demo-client", version: "1.0.0" });
await server.connect(serverTransport);
await client.connect(clientTransport);
const { tools } = await client.listTools();
console.log(tools.map((tool) => tool.name).join(" "));
const result = await client.callTool({ name: "add", arguments: { a: 2, b: 3 } });
console.log(JSON.stringify(result.content));
await client.close();
