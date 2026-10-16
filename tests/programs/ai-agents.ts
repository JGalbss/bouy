// Agents on actors: tools whose execute calls an actor, an actor that calls generateText,
// three agents at once, and an actor crash inside a tool. crates/bouy-cli/tests/ai.rs runs
// it against the fake OpenAI server of runtime/test.
import { spawn, type Ref } from "bouy";
import { generateText, jsonSchema, stepCountIs, streamText, tool } from "ai";
import { createOpenAI, openai } from "@ai-sdk/openai";

class Ledger {
  #entries: string[] = [];

  record(entry: string): string {
    if (entry.length === 0) throw new Error("empty entry");
    this.#entries.push(entry);
    return "ok";
  }

  entries(): string[] {
    return this.#entries;
  }
}

class Agent {
  name: string;
  ledger: Ref<Ledger>;

  constructor(name: string, ledger: Ref<Ledger>) {
    this.name = name;
    this.ledger = ledger;
  }

  async visit(city: string): Promise<string> {
    const ledger: Ref<Ledger> = this.ledger;
    const entry = city.length > 0 ? `${this.name} visits ${city}` : "";
    const result = await generateText({
      // The bare call: Chat Completions in Bouy (contract section 14).
      model: openai("gpt-4o-mini"),
      prompt: `Visit. CALLS [[{"name":"record","input":{"entry":"${entry}"}}]]`,
      tools: {
        record: tool({
          description: "Record a visit",
          inputSchema: jsonSchema<{ entry: string }>({
            type: "object",
            properties: { entry: { type: "string" } },
          }),
          execute: async ({ entry }) => ledger.record(entry),
        }),
      },
      stopWhen: stepCountIs(3),
    });
    return `${this.name}: ${result.text} (${result.steps.length} steps)`;
  }
}

const ledger = spawn(Ledger);
const ana = spawn(Agent, { args: ["ana", ledger] });
const bo = spawn(Agent, { args: ["bo", ledger] });
const cy = spawn(Agent, { args: ["cy", ledger] });

const answers = await Promise.all([ana.visit("Lima"), bo.visit("Oslo"), cy.visit("Rome")]);
for (const answer of answers) console.log(answer);
console.log(JSON.stringify((await ledger.entries()).sort()));

// The ledger throws, so the call of the tool throws ActorFailed, and the model gets the error.
console.log(await ana.visit(""));

const provider = createOpenAI({
  baseURL: process.env.OPENAI_BASE_URL,
  apiKey: process.env.OPENAI_API_KEY,
});
const direct = await generateText({ model: provider("gpt-4o"), prompt: "callable" });
console.log(typeof provider, direct.text, openai.languageModel("m").provider);

try {
  streamText({ model: openai.chat("gpt-4o-mini"), prompt: "stream" });
} catch (error) {
  console.log(String(error));
}
