// streamText over Chat Completions and over the Responses API: each text delta, then the
// totals of the stream.
import { streamText } from "ai";
import { openai } from "@ai-sdk/openai";
import { show } from "../ai/lib/show.ts";

for (const model of [openai.chat("gpt-4o-mini"), openai("gpt-4o-mini")]) {
  const result = streamText({ model, prompt: "Stream a greeting." });
  const deltas: string[] = [];
  for await (const delta of result.textStream) deltas.push(delta);
  console.log(model.provider, show(deltas));
  console.log(await result.text);
  console.log(await result.finishReason, show(await result.usage));
}
