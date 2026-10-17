// generateText with the default model of @ai-sdk/openai, which calls the Responses API.
import { generateText } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "../ai/lib/show.ts";

const result = await generateText({
  model: openai("gpt-4o-mini"),
  system: "You are terse",
  prompt: "Say hello.",
});

console.log(result.text);
console.log(result.finishReason);
console.log(show(result.usage));
console.log(result.response.id, result.response.modelId, result.response.timestamp.toISOString());
console.log(show(result.response.messages));
