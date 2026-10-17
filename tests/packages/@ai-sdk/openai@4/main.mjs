// From the README of @ai-sdk/openai: a provider with its own settings, and its models.
import { createOpenAI } from "@ai-sdk/openai";

const openai = createOpenAI({ apiKey: "sk-test", baseURL: "http://127.0.0.1:9/v1" });
const models = [
  openai("gpt-4o-mini"),
  openai.chat("gpt-4o-mini"),
  openai.responses("gpt-4o-mini"),
  openai.embedding("text-embedding-3-small"),
];
for (const model of models) {
  console.log(model.specificationVersion, model.provider, model.modelId);
}
console.log(Object.keys(openai.tools).sort().join(" "));
