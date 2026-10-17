/** The requests that each transport test makes, and the lines that it prints. */
import type { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { show } from "../../ai/lib/show.ts";

export async function exercise(client: Client): Promise<void> {
  console.log(show(client.getServerVersion()));
  const { tools } = await client.listTools();
  console.log(show(tools.map((tool) => [tool.name, tool.description, tool.inputSchema])));
  console.log(show(await client.callTool({ name: "add", arguments: { a: 2, b: 3 } })));
  console.log(show(await client.callTool({ name: "fail", arguments: { reason: "on purpose" } })));
  console.log(show(await client.readResource({ uri: "greeting://Ada" })));
  console.log(show(await client.getPrompt({ name: "review", arguments: { code: "x = 1" } })));
  const missing = await client
    .callTool({ name: "missing", arguments: {} })
    .catch((error: Error) => error.message);
  console.log(show(missing));
}
