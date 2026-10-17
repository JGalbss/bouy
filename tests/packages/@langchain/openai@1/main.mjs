// From the README of @langchain/openai: a chat model and an embeddings model with their
// settings, and a tool bound to the chat model.
import { tool } from "@langchain/core/tools";
import { ChatOpenAI, OpenAIEmbeddings } from "@langchain/openai";

const model = new ChatOpenAI({ model: "gpt-4o-mini", temperature: 0, apiKey: "sk-test" });
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
const bound = model.bindTools([add]);
console.log(typeof bound.invoke);
const embeddings = new OpenAIEmbeddings({ model: "text-embedding-3-small", apiKey: "sk-test" });
console.log(embeddings.model);
