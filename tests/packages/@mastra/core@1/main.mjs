// From the documentation of @mastra/core: a tool with zod schemas, run on its own.
import { createTool } from "@mastra/core/tools";
import { z } from "zod";

const weather = createTool({
  id: "get-weather",
  description: "Get the weather of a city",
  inputSchema: z.object({ city: z.string() }),
  outputSchema: z.object({ report: z.string() }),
  execute: async (input) => ({ report: `It is sunny in ${input.city}.` }),
});
console.log(weather.id, weather.description);
console.log(JSON.stringify(await weather.execute({ city: "Lima" })));
