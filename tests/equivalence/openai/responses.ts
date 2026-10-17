// The openai package against the Responses API: text, then a function call and its output.
import OpenAI from "openai";
import { show } from "../ai/lib/show.ts";

const client = new OpenAI();

const response = await client.responses.create({
  model: "gpt-4o-mini",
  instructions: "You are terse",
  input: "Say hello.",
});
console.log(response.id, response.status, response.output_text);
console.log(show(response.usage));

const calls = JSON.stringify([[{ name: "lookup", input: { id: 7 } }]]);
const tools: OpenAI.Responses.Tool[] = [
  {
    type: "function",
    name: "lookup",
    parameters: { type: "object", properties: { id: { type: "number" } } },
    strict: false,
  },
];
const first = await client.responses.create({
  model: "gpt-4o-mini",
  input: `Find it. CALLS ${calls}`,
  tools,
});
const call = first.output.find((item) => item.type === "function_call");
console.log(show(call));
if (call?.type === "function_call") {
  const second = await client.responses.create({
    model: "gpt-4o-mini",
    input: [
      { role: "user", content: `Find it. CALLS ${calls}` },
      call,
      { type: "function_call_output", call_id: call.call_id, output: "found 7" },
    ],
    tools,
  });
  console.log(second.output_text);
}
