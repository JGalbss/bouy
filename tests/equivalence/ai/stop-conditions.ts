// stopWhen: stepCountIs, a custom condition, an array of conditions, and a tool without
// execute, which ends the loop because its call has no result.
import { generateText, jsonSchema, stepCountIs, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

const word = jsonSchema<{ word: string }>({
  type: "object",
  properties: { word: { type: "string" } },
});
const tools = {
  echo: tool({
    description: "Repeat a word",
    inputSchema: word,
    execute: async ({ word }) => word,
  }),
  shout: tool({
    description: "Upper-case a word",
    inputSchema: word,
    execute: async ({ word }) => word.toUpperCase(),
  }),
};
const script = JSON.stringify([
  [{ name: "echo", input: { word: "one" } }],
  [{ name: "shout", input: { word: "two" } }],
  [{ name: "echo", input: { word: "three" } }],
]);
const prompt = `Go. CALLS ${script}`;
const model = openai.chat("gpt-4o-mini");

function summary(label: string, result: Awaited<ReturnType<typeof generateText>>): void {
  const names = result.steps.map((step) => step.toolCalls.map((call) => call.toolName).join("+"));
  console.log(
    label,
    result.steps.length,
    result.finishReason,
    show(names),
    JSON.stringify(result.text),
  );
}

summary("two steps", await generateText({ model, prompt, tools, stopWhen: stepCountIs(2) }));
summary(
  "until shout",
  await generateText({
    model,
    prompt,
    tools,
    stopWhen: ({ steps }) =>
      steps.some((step) => step.toolCalls.some((call) => call.toolName === "shout")),
  }),
);
summary(
  "array",
  await generateText({ model, prompt, tools, stopWhen: [stepCountIs(10), () => false] }),
);
summary("one step", await generateText({ model, prompt, tools }));

const manual = await generateText({
  model,
  prompt,
  tools: { echo: tool({ description: "Repeat a word", inputSchema: word }), shout: tools.shout },
  stopWhen: stepCountIs(5),
});
summary("no execute", manual);
console.log(show(manual.toolCalls), manual.toolResults.length, show(manual.response.messages));
