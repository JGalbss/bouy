// From the README of @ai-sdk/google: a provider with its own settings, and its models.
import { createGoogleGenerativeAI } from "@ai-sdk/google";

const google = createGoogleGenerativeAI({ apiKey: "test-key", baseURL: "http://127.0.0.1:9/v1" });
const models = [google("gemini-2.5-flash"), google.chat("gemini-2.5-pro")];
for (const model of models) {
  console.log(model.specificationVersion, model.provider, model.modelId);
}
console.log(Object.keys(google.tools).sort().join(" "));
