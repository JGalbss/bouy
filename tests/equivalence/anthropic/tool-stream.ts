// A streamed tool call: the events of the stream, the tool_use block of the final message,
// then the tool result and the final answer.
import Anthropic from "@anthropic-ai/sdk";
import { show } from "../ai/lib/show.ts";

const client = new Anthropic();
const tools: Anthropic.Tool[] = [
  {
    name: "weather",
    description: "The weather of a city",
    input_schema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] },
  },
];
const question = `Weather in Lima? CALLS ${JSON.stringify([[{ name: "weather", input: { city: "Lima" } }]])}`;

const stream = client.messages.stream({
  model: "claude-fake",
  max_tokens: 100,
  tools,
  messages: [{ role: "user", content: question }],
});
stream.on("inputJson", (partial, snapshot) => console.log("input", partial, show(snapshot)));
const types: string[] = [];
for await (const event of stream) types.push(event.type);
console.log(show(types));
const message = await stream.finalMessage();
console.log(message.stop_reason, show(message.content));

const use = message.content.find((block) => block.type === "tool_use");
if (use?.type === "tool_use") {
  const answer = client.messages.stream({
    model: "claude-fake",
    max_tokens: 100,
    tools,
    messages: [
      { role: "user", content: question },
      { role: "assistant", content: message.content },
      {
        role: "user",
        content: [{ type: "tool_result", tool_use_id: use.id, content: "sunny, 21 C" }],
      },
    ],
  });
  answer.on("text", (delta) => console.log("text", JSON.stringify(delta)));
  const final = await answer.finalMessage();
  console.log(final.stop_reason, await answer.finalText());
  console.log(show(final.usage));
}
