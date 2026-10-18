// Multi-step tool calling: the fake model calls the tools that the prompt scripts, one
// entry per step, then answers with the tool results.
import { generateText, jsonSchema, stepCountIs, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

const numbers = jsonSchema<{ a: number; b: number }>({
  type: "object",
  properties: { a: { type: "number" }, b: { type: "number" } },
  required: ["a", "b"],
});

const tools = {
  add: tool({
    description: "Add two numbers",
    inputSchema: numbers,
    execute: async ({ a, b }) => a + b,
  }),
  multiply: tool({
    description: "Multiply two numbers",
    inputSchema: numbers,
    execute: async ({ a, b }) => ({ product: a * b }),
  }),
  shout: tool({
    description: "Upper-case a word",
    inputSchema: jsonSchema<{ word: string }>({
      type: "object",
      properties: { word: { type: "string" } },
    }),
    // The only tool of its step, so its line prints at the same place in Node and Buoy.
    execute: async ({ word }, { toolCallId, messages }) => {
      console.log("shout", toolCallId, "after", messages.length, "messages");
      return word.toUpperCase();
    },
  }),
};

const script = JSON.stringify([
  [
    { name: "add", input: { a: 2, b: 3 } },
    { name: "multiply", input: { a: 4, b: 5 } },
  ],
  [{ name: "shout", input: { word: "done" } }],
]);

const result = await generateText({
  model: openai.chat("gpt-4o-mini"),
  system: "You are a calculator",
  prompt: `Compute. CALLS ${script}`,
  tools,
  stopWhen: stepCountIs(5),
});

console.log(result.text);
console.log(result.steps.length, result.finishReason);
for (const step of result.steps) {
  console.log(
    `step ${step.stepNumber}: ${step.finishReason} ${step.rawFinishReason} text=${JSON.stringify(step.text)}`,
  );
  console.log("  calls", show(step.toolCalls));
  console.log("  results", show(step.toolResults));
  console.log("  content", show(step.content.map((part) => part.type)));
  console.log("  usage", show(step.usage));
  console.log(
    "  response",
    step.response.id,
    step.response.modelId,
    step.response.timestamp.toISOString(),
  );
  console.log("  messages", show(step.response.messages));
}
console.log(show(result.toolCalls.map((call) => [call.toolCallId, call.toolName, call.input])));
console.log(show(result.toolResults.map((each) => [each.toolCallId, each.output])));
console.log(result.staticToolCalls.length, result.dynamicToolCalls.length);
console.log(result.staticToolResults.length, result.dynamicToolResults.length);
console.log(show(result.totalUsage));
console.log(show(result.responseMessages));
console.log(show(result.response.messages));

// The same script under the default stop condition ends after the first step.
const first = await generateText({
  model: openai.chat("gpt-4o-mini"),
  prompt: `Compute. CALLS ${script}`,
  tools,
});
console.log(
  first.steps.length,
  first.finishReason,
  JSON.stringify(first.text),
  first.toolResults.length,
);
