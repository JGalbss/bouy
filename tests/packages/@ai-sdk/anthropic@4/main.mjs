// From the README of @ai-sdk/anthropic: a provider with its own settings, and its models.
import { createAnthropic } from "@ai-sdk/anthropic";

const anthropic = createAnthropic({ apiKey: "sk-test", baseURL: "http://127.0.0.1:9/v1" });
for (const model of [anthropic("claude-sonnet-4-5"), anthropic.messages("claude-haiku-4-5")]) {
  console.log(model.specificationVersion, model.provider, model.modelId);
}
console.log(Object.keys(anthropic.tools).sort().join(" "));
