// generateText with a system prompt: the text, the finish reason, the usage, and the
// response metadata of one step.
import { generateText } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

const result = await generateText({
  model: openai.chat("gpt-4o-mini"),
  system: "You are terse",
  prompt: "Say hello",
});

console.log(result.text);
console.log(result.finishReason, result.rawFinishReason, result.output);
console.log(show(result.usage));
console.log(show(result.totalUsage));
console.log(result.response.id, result.response.modelId, result.response.timestamp.toISOString());
console.log(show(result.response.headers));
console.log(show(result.response.messages));
console.log(show(result.responseMessages));
console.log(result.steps.length, result.steps[0].stepNumber, show(result.steps[0].model));
console.log(show(result.content));
console.log(show(result.providerMetadata), result.warnings.length);
console.log(
  result.toolCalls.length,
  result.toolResults.length,
  result.files.length,
  result.sources.length,
);
console.log(show(result.request), result.reasoningText);

const step = result.steps[0];
console.log(step.text === result.text, step.finishReason, show(step.usage) === show(result.usage));

const length = await generateText({ model: openai.chat("fake-length"), prompt: "Cut me short" });
console.log(length.finishReason, length.rawFinishReason, length.text);
