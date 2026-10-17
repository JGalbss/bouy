// Tools with zod input schemas: the model calls them in two steps, then answers with the
// results.
import { generateText, stepCountIs, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { z } from "zod";
import { show } from "../ai/lib/show.ts";

const tools = {
  weather: tool({
    description: "The weather of a city",
    inputSchema: z.object({ city: z.string(), unit: z.enum(["C", "F"]).default("C") }),
    execute: async ({ city, unit }) => ({ city, temperature: city.length * 3, unit }),
  }),
  advise: tool({
    description: "Advice for a temperature",
    inputSchema: z.object({ temperature: z.number().int() }),
    execute: async ({ temperature }) => (temperature > 15 ? "go out" : "stay in"),
  }),
};

const script = JSON.stringify([
  [{ name: "weather", input: { city: "Lima" } }],
  [{ name: "advise", input: { temperature: 12 } }],
]);

for (const model of [openai.chat("gpt-4o-mini"), openai("gpt-4o-mini")]) {
  const result = await generateText({
    model,
    prompt: `Plan my day. CALLS ${script}`,
    tools,
    stopWhen: stepCountIs(3),
  });
  console.log(model.provider, result.text);
  for (const step of result.steps) {
    console.log(
      `  step ${step.stepNumber} ${step.finishReason}`,
      show(step.toolCalls.map((call) => call.input)),
    );
    console.log("  results", show(step.toolResults.map((each) => each.output)));
  }
}

const invalid = await generateText({
  model: openai.chat("gpt-4o-mini"),
  prompt: `Bad input. CALLS ${JSON.stringify([[{ name: "advise", input: { temperature: "warm" } }]])}`,
  tools,
  stopWhen: stepCountIs(2),
});
console.log(show(invalid.steps[0]?.content.map((part) => part.type)));
console.log(invalid.text);
