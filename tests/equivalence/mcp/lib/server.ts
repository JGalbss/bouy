/** The MCP server of every transport: two tools, a resource, and a prompt. */
import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

export function createServer(): McpServer {
  const server = new McpServer({ name: "bouy-test-server", version: "1.0.0" });
  server.registerTool(
    "add",
    {
      description: "Add two numbers",
      inputSchema: { a: z.number(), b: z.number() },
      outputSchema: { sum: z.number() },
    },
    async ({ a, b }) => ({
      content: [{ type: "text", text: String(a + b) }],
      structuredContent: { sum: a + b },
    }),
  );
  server.registerTool(
    "fail",
    { description: "Always fails", inputSchema: { reason: z.string() } },
    async ({ reason }) => {
      throw new Error(`failed: ${reason}`);
    },
  );
  server.registerResource(
    "greeting",
    new ResourceTemplate("greeting://{name}", { list: undefined }),
    { description: "A greeting for a name" },
    async (uri, { name }) => ({ contents: [{ uri: uri.href, text: `Hello, ${String(name)}!` }] }),
  );
  server.registerPrompt(
    "review",
    { description: "Review some code", argsSchema: { code: z.string() } },
    ({ code }) => ({
      messages: [{ role: "user", content: { type: "text", text: `Review this: ${code}` } }],
    }),
  );
  return server;
}
