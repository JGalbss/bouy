// An MCP client that starts its server as a child process and talks to it over stdio.
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { exercise } from "./lib/exercise.ts";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [fileURLToPath(new URL("./stdio-server-fixture.ts", import.meta.url))],
  stderr: "ignore",
});
const client = new Client({ name: "buoy-test-client", version: "1.0.0" });
await client.connect(transport);
await exercise(client);
await client.close();
