// The MCP server of stdio.ts, which starts this file as a child process.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./lib/server.ts";

await createServer().connect(new StdioServerTransport());
