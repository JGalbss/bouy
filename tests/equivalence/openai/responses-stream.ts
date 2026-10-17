// A streamed response: the type of each event, the text deltas, and the final response.
import OpenAI from "openai";

const client = new OpenAI();

const stream = await client.responses.create({
  model: "gpt-4o-mini",
  input: "Stream a greeting.",
  stream: true,
});
const deltas: string[] = [];
for await (const event of stream) {
  console.log(event.sequence_number, event.type);
  if (event.type === "response.output_text.delta") deltas.push(event.delta);
  if (event.type === "response.completed") console.log(event.response.status, event.response.id);
}
console.log(JSON.stringify(deltas));

const helper = client.responses.stream({ model: "gpt-4o-mini", input: "Again." });
helper.on("response.output_text.delta", (event) =>
  console.log("delta", JSON.stringify(event.delta)),
);
const final = await helper.finalResponse();
console.log(final.id, final.output_text);
