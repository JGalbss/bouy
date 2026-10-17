// From the testing guide of ai: generateText and streamText against the mock model of ai/test.
import { generateText, streamText, simulateReadableStream } from "ai";
import { MockLanguageModelV4 } from "ai/test";

const finishReason = { unified: "stop", raw: undefined };
const usage = {
  inputTokens: { total: 3, noCache: 3, cacheRead: undefined, cacheWrite: undefined },
  outputTokens: { total: 4, text: 4, reasoning: undefined },
};
const model = new MockLanguageModelV4({
  doGenerate: async () => ({
    content: [{ type: "text", text: "Hello, world!" }],
    finishReason,
    usage,
    warnings: [],
  }),
  doStream: async () => ({
    stream: simulateReadableStream({
      chunks: [
        { type: "text-start", id: "text-1" },
        { type: "text-delta", id: "text-1", delta: "Hello" },
        { type: "text-delta", id: "text-1", delta: ", world!" },
        { type: "text-end", id: "text-1" },
        { type: "finish", finishReason, logprobs: undefined, usage },
      ],
    }),
  }),
});

const generated = await generateText({ model, prompt: "Say hello." });
console.log(generated.text, generated.finishReason, generated.usage.totalTokens);

const streamed = streamText({ model, prompt: "Say hello." });
const deltas = [];
for await (const delta of streamed.textStream) deltas.push(delta);
console.log(JSON.stringify(deltas), await streamed.finishReason);
