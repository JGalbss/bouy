import type { PlanStep } from "./parse.ts";

export interface PinnedCall {
  name: string;
  input: Record<string, unknown>;
}

export namespace Prompts {
  export const PLANNER =
    "You are a research planner. Answer with numbered steps, one per line, each a tool name and its argument";
  export const RESEARCHER =
    "You are a careful research assistant. Make the tool calls of the step, then report their results";
  export const SUMMARIZER = "You write short executive summaries for engineers";

  export function plan(topic: string, outline: readonly string[]): string {
    const lines = outline.map((item, i) => `${i + 1}. ${item}`);
    return [`Topic: ${topic}`, "Suggested outline:", ...lines].join("\n");
  }

  export function research(step: PlanStep, calls: PinnedCall[][]): string {
    return `Step ${step.index} (${step.kind}): ${step.argument}.${pin(calls)}`;
  }

  export function summarize(topic: string, findings: readonly string[]): string {
    const bullets = findings.map((finding) => `- ${finding}`).join("\n");
    return `Topic: ${topic}\nFindings:\n${bullets}`;
  }

  /**
   * Pins the tool calls of a step: one array of calls per model step. The evaluation model
   * (and the local fake server) honor the CALLS suffix; production models ignore it.
   */
  function pin(calls: PinnedCall[][]): string {
    return calls.length === 0 ? "" : ` CALLS ${JSON.stringify(calls)}`;
  }
}

/** The tool calls that carry out one plan step. */
export function pinnedCallsFor(step: PlanStep): PinnedCall[][] {
  switch (step.kind) {
    case "search":
      return [
        [{ name: "search", input: { query: step.argument } }],
        [{ name: "take_note", input: { text: `searched "${step.argument}"` } }],
      ];
    case "fetch":
      return [step.argument.split(/\s+/).map((url) => ({ name: "fetch_page", input: { url } }))];
    case "calc":
      return [[{ name: "calculate", input: { expression: step.argument } }]];
    case "summarize":
      return [];
  }
}
