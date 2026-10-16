// Tool failures go back to the model as tool results: a thrown Error, a thrown string, a
// call of a tool that does not exist, and arguments that are not JSON.
import { generateText, jsonSchema, stepCountIs, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

const numbers = jsonSchema<{ a: number; b: number }>({
  type: "object",
  properties: { a: { type: "number" }, b: { type: "number" } },
});
const tools = {
  add: tool({ description: "Add", inputSchema: numbers, execute: async ({ a, b }) => a + b }),
  fail: tool({
    description: "Fail",
    inputSchema: numbers,
    execute: async ({ a }): Promise<number> => {
      if (a > 0) throw new Error("boom");
      throw "plain failure";
    },
  }),
};
const script = JSON.stringify([
  [{ name: "fail", input: { a: 1, b: 0 } }],
  [{ name: "fail", input: { a: 0, b: 0 } }],
  [{ name: "missing", input: { a: 1, b: 2 } }],
  [{ name: "add", arguments: "#oops" }],
  [{ name: "add", arguments: "" }],
]);

const result = await generateText({
  model: openai.chat("gpt-4o-mini"),
  prompt: `Try. CALLS ${script}`,
  tools,
  stopWhen: stepCountIs(10),
});

console.log(result.text);
console.log(result.steps.length, result.finishReason);
for (const step of result.steps) {
  const errors = step.content.filter((part) => part.type === "tool-error");
  console.log(`step ${step.stepNumber}:`, show(step.content.map((part) => part.type)));
  for (const error of errors) {
    const value = error.error;
    const text = value instanceof Error ? `${value.name}: ${value.message}` : String(value);
    console.log("  error", error.toolName, JSON.stringify(error.input), error.dynamic, text);
  }
  for (const call of step.toolCalls) {
    console.log(
      "  call",
      call.toolName,
      JSON.stringify(call.input),
      call.dynamic === true,
      call.invalid === true,
    );
  }
  console.log(
    "  tool message",
    show(step.response.messages.filter((message) => message.role === "tool")),
  );
}
console.log(
  result.staticToolCalls.length,
  result.dynamicToolCalls.length,
  result.toolResults.length,
);
