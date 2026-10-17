// From the README of @openai/agents: an agent with instructions and a tool, and a handoff to
// a second agent. The program builds them and does not run them.
import { Agent, handoff, tool } from "@openai/agents";
import { z } from "zod";

const weather = tool({
  name: "get_weather",
  description: "Get the weather of a city",
  parameters: z.object({ city: z.string() }),
  execute: async ({ city }) => `It is sunny in ${city}.`,
});
const forecaster = new Agent({ name: "Forecaster", instructions: "Answer with the weather." });
const agent = new Agent({
  name: "Assistant",
  instructions: "You are a helpful assistant.",
  tools: [weather],
  handoffs: [handoff(forecaster)],
});
console.log(agent.name, agent.instructions, agent.tools.map((each) => each.name).join(" "));
console.log(agent.handoffs.map((each) => each.toolName ?? each.name).join(" "));
console.log(JSON.stringify(weather.parameters.properties));
console.log(await weather.invoke(undefined, JSON.stringify({ city: "Lima" })));
