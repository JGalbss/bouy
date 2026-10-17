// From the README of @ai-sdk/gateway: a gateway provider and the models that it names.
import { createGateway } from "@ai-sdk/gateway";

const gateway = createGateway({ apiKey: "test-key", baseURL: "http://127.0.0.1:9/v1/ai" });
for (const id of ["openai/gpt-4o-mini", "anthropic/claude-sonnet-4-5"]) {
  const model = gateway(id);
  console.log(model.specificationVersion, model.provider, model.modelId);
}
console.log(typeof gateway.getAvailableModels);
