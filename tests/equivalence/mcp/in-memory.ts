// An MCP server and client in one program, joined by a linked pair of in-memory transports.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createServer } from "./lib/server.ts";
import { exercise } from "./lib/exercise.ts";

const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
const server = createServer();
const client = new Client({ name: "buoy-test-client", version: "1.0.0" });
await server.connect(serverTransport);
await client.connect(clientTransport);
await exercise(client);
await client.close();
await server.close();
