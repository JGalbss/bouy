// Models of the default provider and of createOpenAI, and a conversation that feeds the
// response messages of each turn back as messages.
import { generateText, jsonSchema, stepCountIs, tool, type ModelMessage } from "ai";
import { createOpenAI, openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

const model = openai.chat("gpt-4o-mini");
console.log(model.provider, model.modelId, model.specificationVersion);

const named = createOpenAI({
  baseURL: process.env.OPENAI_BASE_URL,
  apiKey: "sk-fake-key",
  name: "proxy",
});
const proxied = named.chat("gpt-4o");
console.log(proxied.provider, proxied.modelId);
const greeting = await generateText({ model: proxied, prompt: "Hello from a named provider" });
console.log(greeting.text, show(greeting.steps[0].model), greeting.response.modelId);

const tools = {
  lookup: tool({
    description: "Look up a city",
    inputSchema: jsonSchema<{ city: string }>({
      type: "object",
      properties: { city: { type: "string" } },
    }),
    execute: async ({ city }) => ({ city, population: city.length * 1000 }),
  }),
};

// Bouy keeps module-level values constant, so the history lives in a function.
async function converse(): Promise<void> {
  const messages: ModelMessage[] = [{ role: "user", content: "Tell me about Lima" }];
  for (const city of ["Lima", "Oslo"]) {
    if (city !== "Lima") {
      messages.push({
        role: "user",
        content: `And ${city}? CALLS [[{"name":"lookup","input":{"city":"${city}"}}]]`,
      });
    }
    const turn = await generateText({
      model,
      system: "You know cities",
      messages,
      tools,
      stopWhen: stepCountIs(3),
    });
    console.log(turn.text);
    console.log(turn.steps.length, show(turn.response.messages.map((message) => message.role)));
    messages.push(...turn.responseMessages);
  }
  console.log(messages.length, show(messages.map((message) => message.role)));
  console.log(show(messages));
}

await converse();
