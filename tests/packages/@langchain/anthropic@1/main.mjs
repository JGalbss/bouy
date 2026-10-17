// From the README of @langchain/anthropic: a chat model with its settings, and a tool bound
// to it.
import { tool } from "@langchain/core/tools";
import { ChatAnthropic } from "@langchain/anthropic";

const model = new ChatAnthropic({ model: "claude-sonnet-4-5", temperature: 0, apiKey: "sk-test" });
console.log(model.model, model.temperature, model._llmType());
const add = tool(async ({ a, b }) => String(a + b), {
  name: "add",
  description: "Add two numbers",
  schema: {
    type: "object",
    properties: { a: { type: "number" }, b: { type: "number" } },
    required: ["a", "b"],
  },
});
console.log(typeof model.bindTools([add]).invoke);
