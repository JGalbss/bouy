// Parsers for model output. Models do not always follow the format, so every parser accepts
// some noise and returns what it could read.

export type StepKind = "search" | "fetch" | "calc" | "summarize";

export interface PlanStep {
  index: number;
  kind: StepKind;
  argument: string;
}

const PLAN_LINE = /^\s*(\d+)[.)]\s+(search|fetch|calc|summarize)\s*:\s*(.+?)\s*$/gim;

/** Reads lines such as `2. search: beam scheduler` from a plan. Duplicate steps are dropped. */
export function parsePlan(text: string): PlanStep[] {
  const steps: PlanStep[] = [];
  const seen = new Set<string>();
  for (const match of text.matchAll(PLAN_LINE)) {
    const [, index, kind, argument] = match;
    const key = `${kind.toLowerCase()}:${argument.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    steps.push({ index: Number(index), kind: kind.toLowerCase() as StepKind, argument });
  }
  return steps;
}

export interface ToolOutput {
  tool: string;
  output: string;
}

const RESULT_ENTRY = /(\w+) -> (.*?)(?=, \w+ -> |$)/gs;

/** Reads `Results: search -> [...], take_note -> {...}` into one entry per tool call. */
export function parseToolResults(text: string): ToolOutput[] {
  const body = text.match(/^Results:\s*(.*)$/s)?.[1];
  if (body === undefined) return [];
  const outputs: ToolOutput[] = [];
  let match: RegExpExecArray | null;
  RESULT_ENTRY.lastIndex = 0;
  while ((match = RESULT_ENTRY.exec(body)) !== null) {
    outputs.push({ tool: match[1], output: match[2].trim() });
  }
  return outputs;
}

const URL_PATTERN = /https?:\/\/[^\s"'<>),\]]+/g;

export function extractUrls(text: string): string[] {
  return [...new Set(text.match(URL_PATTERN) ?? [])];
}

const GREETING = /^(?:hello|hi|hey)[!,.]?\s+/i;
const SENTENCE = /[^.!?]+[.!?]+(?=\s|$)/g;

/** Drops a leading greeting and keeps the first `count` sentences. */
export function firstSentences(text: string, count: number): string {
  const sentences = text.replace(GREETING, "").match(SENTENCE) ?? [text];
  return sentences
    .slice(0, count)
    .map((sentence) => sentence.trim())
    .join(" ");
}
