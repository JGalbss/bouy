// Structured output with a zod schema: the model answers with JSON, and ai parses and
// validates it.
import { generateText, Output, streamText } from "ai";
import { openai } from "@ai-sdk/openai";
import { z } from "zod";
import { show } from "../ai/lib/show.ts";

const trip = z.object({
  city: z.string(),
  days: z.number().int().positive(),
  sights: z.array(z.string()),
});
const answer = JSON.stringify({ city: "Lima", days: 3, sights: ["Miraflores", "Barranco"] });

for (const model of [openai.chat("gpt-4o-mini"), openai("gpt-4o-mini")]) {
  const result = await generateText({
    model,
    output: Output.object({ schema: trip }),
    prompt: `Plan a trip. JSON ${answer}`,
  });
  console.log(model.provider, show(result.output));
}

const streamed = streamText({
  model: openai.chat("gpt-4o-mini"),
  output: Output.object({ schema: trip }),
  prompt: `Plan a trip. JSON ${answer}`,
});
const partials: unknown[] = [];
for await (const partial of streamed.partialOutputStream) partials.push(partial);
console.log(partials.length > 0, show(partials.at(-1)));
console.log(show(await streamed.output));

try {
  await generateText({
    model: openai.chat("gpt-4o-mini"),
    output: Output.object({ schema: trip }),
    prompt: `Plan a trip. JSON ${JSON.stringify({ city: "Lima", days: -1, sights: [] })}`,
  });
} catch (error) {
  console.log((error as Error).name);
}
