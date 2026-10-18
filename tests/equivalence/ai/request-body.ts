// The request that reaches the server: a model whose name ends in "echo" answers with the
// request body and headers, so this program compares what Node and Buoy send.
import { generateText, jsonSchema, tool } from "ai";
import { createOpenAI, openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

async function echo(options: Record<string, unknown>): Promise<void> {
  const result = await generateText({ model: openai.chat("fake-echo"), ...options } as any);
  console.log(result.text);
}

// A required tool choice that the model ignores throws, with the content of the response.
async function echoViolation(options: Record<string, unknown>): Promise<void> {
  try {
    await echo(options);
  } catch (error: any) {
    console.log(error.name, error.message, error.finishReason, error.provider, error.modelId);
    console.log(show(error.toolChoice), error.content[0].text);
  }
}

await echo({ system: "Be brief", prompt: "hi" });
await echo({
  instructions: "Use settings",
  prompt: "settings",
  maxOutputTokens: 100,
  temperature: 0.5,
  topP: 0.9,
  presencePenalty: 0.1,
  frequencyPenalty: 0.2,
  stopSequences: ["END"],
  seed: 7,
});
await echo({
  instructions: [
    { role: "system", content: "First" },
    { role: "system", content: "Second" },
  ],
  messages: [
    { role: "user", content: "a" },
    { role: "assistant", content: "b" },
    {
      role: "user",
      content: [
        { type: "text", text: "c" },
        { type: "text", text: "" },
      ],
    },
    {
      role: "user",
      content: [
        { type: "text", text: "d" },
        { type: "text", text: "e" },
      ],
    },
  ],
});
await echo({
  messages: [
    { role: "user", content: "What is 2 + 3?" },
    {
      role: "assistant",
      content: [
        { type: "text", text: "Let me add." },
        { type: "tool-call", toolCallId: "call_a", toolName: "add", input: { a: 2, b: 3 } },
      ],
    },
    {
      role: "tool",
      content: [
        {
          type: "tool-result",
          toolCallId: "call_a",
          toolName: "add",
          output: { type: "json", value: { sum: 5 } },
        },
      ],
    },
    {
      role: "assistant",
      content: [
        { type: "tool-call", toolCallId: "call_b", toolName: "add", input: { a: 5, b: 1 } },
      ],
    },
    {
      role: "tool",
      content: [
        {
          type: "tool-result",
          toolCallId: "call_b",
          toolName: "add",
          output: { type: "text", value: "six" },
        },
        {
          type: "tool-result",
          toolCallId: "call_c",
          toolName: "add",
          output: { type: "error-text", value: "boom" },
        },
      ],
    },
    { role: "user", content: "Thanks" },
  ],
});

const tools = {
  add: tool({
    description: "Add two numbers",
    inputSchema: jsonSchema({
      type: "object",
      properties: { a: { type: "number" }, b: { type: "number" } },
      required: ["a", "b"],
      additionalProperties: false,
    }),
    execute: async ({ a, b }: { a: number; b: number }) => a + b,
  }),
  now: tool({ description: "The time", strict: true, execute: async () => "noon" }),
};
await echo({ prompt: "tools", tools });
await echoViolation({ prompt: "required", tools, toolChoice: "required" });
await echo({ prompt: "none", tools, toolChoice: "none" });
await echoViolation({ prompt: "one tool", tools, toolChoice: { type: "tool", toolName: "now" } });
await echo({ prompt: "headers", headers: { "X-Trace": "t1" } });

const reasoning = await generateText({
  model: openai.chat("o4-mini-echo"),
  system: "Think",
  prompt: "reason",
  temperature: 0.3,
  maxOutputTokens: 50,
});
console.log(reasoning.text);
console.log(show(reasoning.warnings));

const provider = createOpenAI({
  baseURL: process.env.OPENAI_BASE_URL + "/",
  apiKey: "sk-fake-key",
  organization: "org-1",
  project: "proj-1",
  headers: { "X-Extra": "e" },
});
const custom = await generateText({ model: provider.chat("fake-echo"), prompt: "custom" });
console.log(custom.text);
