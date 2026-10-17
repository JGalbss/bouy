// The openai package against Chat Completions: one answer, a tool call, and an API error.
import OpenAI from "openai";
import { show } from "../ai/lib/show.ts";

const client = new OpenAI();

const completion = await client.chat.completions.create({
  model: "gpt-4o-mini",
  messages: [
    { role: "system", content: "You are terse" },
    { role: "user", content: "Say hello." },
  ],
});
console.log(completion.id, completion.model, completion.choices[0]?.finish_reason);
console.log(completion.choices[0]?.message.content);
console.log(show(completion.usage));

const calls = JSON.stringify([[{ name: "lookup", input: { id: 7 } }]]);
const withTools = await client.chat.completions.create({
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
console.log(show(withTools.choices[0]?.message.tool_calls));

try {
  await client.chat.completions.create(
    { model: "fake-500", messages: [{ role: "user", content: "Fail." }] },
    { maxRetries: 0 },
  );
} catch (error) {
  const failure = error as InstanceType<typeof OpenAI.APIError>;
  console.log(failure instanceof OpenAI.InternalServerError, failure.status, failure.message);
}
