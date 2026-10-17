// A streamed chat completion: the content deltas, then a streamed tool call.
import OpenAI from "openai";
import { show } from "../ai/lib/show.ts";

const client = new OpenAI();

const stream = await client.chat.completions.create({
  model: "gpt-4o-mini",
  messages: [{ role: "user", content: "Stream a greeting." }],
  stream: true,
  stream_options: { include_usage: true },
});
const deltas: string[] = [];
for await (const chunk of stream) {
  const choice = chunk.choices[0];
  if (choice?.delta.content) deltas.push(choice.delta.content);
  if (choice?.finish_reason) console.log("finish", choice.finish_reason);
  if (chunk.usage) console.log("usage", show(chunk.usage));
}
console.log(show(deltas));

const calls = JSON.stringify([[{ name: "lookup", input: { id: 7 } }]]);
const runner = client.chat.completions.stream({
  model: "gpt-4o-mini",
  messages: [{ role: "user", content: `Find it. CALLS ${calls}` }],
  tools: [
    {
      type: "function",
      function: {
        name: "lookup",
        parameters: { type: "object", properties: { id: { type: "number" } } },
      },
    },
  ],
});
const final = await runner.finalChatCompletion();
console.log(final.choices[0]?.finish_reason, show(final.choices[0]?.message.tool_calls));
