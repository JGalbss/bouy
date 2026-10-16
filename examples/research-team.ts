import { createOpenAI } from "@ai-sdk/openai";
import { generateText, isStepCount, streamText, tool, type LanguageModel } from "ai";
import { child, inspect, shutdown, signal, supervise, tree, withSignal, type Ref } from "bouy";
import { z } from "zod";
import { FakeOpenAI } from "./fake-openai.ts";

interface ModelSettings {
  readonly baseURL: string;
}

interface Finding {
  readonly topic: string;
  readonly answer: string;
  readonly toolCalls: number;
}

const chatModel = (settings: ModelSettings): LanguageModel =>
  createOpenAI({ baseURL: settings.baseURL, apiKey: "test" }).chat("gpt-5");

class WebSearch {
  readonly #index = new Map<string, ReadonlyArray<string>>([
    ["actor model", ["An actor owns its state.", "Actors talk only through messages."]],
    ["supervision trees", ["A supervisor restarts a failed child with fresh state."]],
  ]);

  query(query: string): ReadonlyArray<string> {
    const hits = this.#index.get(query);
    if (hits === undefined) throw new Error(`the search index has no entry for "${query}"`);
    return hits;
  }
}

class ResearchAgent {
  readonly #model: LanguageModel;

  constructor(settings: ModelSettings) {
    this.#model = chatModel(settings);
  }

  async research(topic: string, search: Ref<WebSearch>): Promise<Finding> {
    const result = await generateText({
      model: this.#model,
      system: "Search the web before you answer.",
      prompt: topic,
      tools: {
        webSearch: tool({
          description: "Search the web for one topic.",
          inputSchema: z.object({ query: z.string() }),
          execute: (input, { abortSignal }) =>
            withSignal(abortSignal ?? signal(), () => search.query(input.query)),
        }),
      },
      stopWhen: isStepCount(2),
      abortSignal: signal(),
    });
    return {
      topic,
      answer: result.text,
      toolCalls: result.steps.flatMap((step) => step.toolCalls).length,
    };
  }
}

class Writer {
  readonly #model: LanguageModel;

  constructor(settings: ModelSettings) {
    this.#model = chatModel(settings);
  }

  async *summarize(findings: ReadonlyArray<Finding>): AsyncGenerator<string> {
    const topics = findings.map((finding) => finding.topic).join(", ");
    const summary = streamText({
      model: this.#model,
      prompt: `Summarize the research on ${topics}.`,
      abortSignal: signal(),
    });
    yield* summary.textStream;
  }
}

const llm = await FakeOpenAI.start({ latencyMs: 100 });
const settings: ModelSettings = { baseURL: llm.baseURL };

const team = supervise({
  strategy: "one-for-one",
  children: {
    search: child(WebSearch),
    writer: child(Writer, { args: [settings] }),
    researchers: tree({
      strategy: "one-for-one",
      children: {
        ada: child(ResearchAgent, { args: [settings] }),
        grace: child(ResearchAgent, { args: [settings] }),
        linus: child(ResearchAgent, { args: [settings] }),
      },
    }),
  },
});

const assignments = [
  { researcher: team.researchers.ada, topic: "actor model" },
  { researcher: team.researchers.grace, topic: "supervision trees" },
  { researcher: team.researchers.linus, topic: "green threads" },
];

const findings = await Promise.all(
  assignments.map(({ researcher, topic }) => researcher.research(topic, team.search)),
);
for (const finding of findings) {
  console.log(`${finding.topic} (${finding.toolCalls} tool call): ${finding.answer}`);
}

const chunks: Array<string> = [];
for await (const chunk of team.writer.summarize(findings)) chunks.push(chunk);
console.log(`summary (${chunks.length} chunks): ${chunks.join("")}`);

console.log(
  `The fake model served ${llm.served} requests, at most ${llm.peakConcurrency} at once.`,
);
for (const actor of inspect()) console.log(`${actor.name}: restarts ${actor.restarts}`);

await shutdown();
await llm.stop();
