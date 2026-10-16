import type { TtlCache } from "../cache.ts";
import { memoize } from "../cache.ts";
import { ToolError } from "../errors.ts";
import type { TokenBucket } from "../rate-limiter.ts";
import { sleep } from "../util/async.ts";
import { CORPUS } from "./corpus.ts";
import type { ToolRegistry } from "./registry.ts";

export interface SearchHit {
  url: string;
  title: string;
  score: number;
}

export interface Page {
  url: string;
  title: string;
  excerpt: string;
}

const tokenize = memoize((text: string): string[] =>
  text
    .toLowerCase()
    .split(/[^a-z0-9_]+/)
    .filter((word) => word.length > 2),
);

export function searchCorpus(query: string, limit = 2): SearchHit[] {
  const terms = tokenize(query);
  const hits: SearchHit[] = [];
  CORPUS.forEach((doc) => {
    const words = new Set(tokenize(`${doc.title} ${doc.body} ${doc.tags.join(" ")}`));
    let score = 0;
    terms.forEach((term) => {
      if (words.has(term)) score++;
    });
    if (score > 0) hits.push({ url: doc.url, title: doc.title, score });
  });
  return hits.sort((a, b) => b.score - a.score || a.url.localeCompare(b.url)).slice(0, limit);
}

const BINARY_EXPRESSION = /^\s*(-?\d+(?:\.\d+)?)\s*([-+*/])\s*(-?\d+(?:\.\d+)?)\s*$/;

export function evaluate(expression: string): number {
  const match = BINARY_EXPRESSION.exec(expression);
  if (!match) throw new ToolError("calculate", `cannot parse "${expression}"`);
  const [, left, operator, right] = match;
  const a = Number(left);
  const b = Number(right);
  switch (operator) {
    case "+":
      return a + b;
    case "-":
      return a - b;
    case "*":
      return a * b;
    case "/":
      if (b === 0) throw new ToolError("calculate", "division by zero");
      return a / b;
    default:
      throw new ToolError("calculate", `unsupported operator "${operator}"`);
  }
}

export interface BuiltinToolDeps {
  cache: TtlCache<string, unknown>;
  /** Politeness limit for the docs site. */
  webLimiter: TokenBucket;
  fetchLatencyMs: number;
}

export function registerBuiltinTools(registry: ToolRegistry, deps: BuiltinToolDeps): ToolRegistry {
  const { cache, webLimiter, fetchLatencyMs } = deps;

  return registry
    .register<{ query: string }, SearchHit[]>({
      name: "search",
      description: "Search the documentation index. Returns the best matching pages.",
      parameters: {
        type: "object",
        properties: { query: { type: "string" } },
        required: ["query"],
      },
      execute: async ({ query }) =>
        (await cache.getOrLoad(`search:${query}`, async () => searchCorpus(query))) as SearchHit[],
    })
    .register<{ url: string }, Page>({
      name: "fetch_page",
      description: "Fetch a documentation page by URL.",
      parameters: {
        type: "object",
        properties: { url: { type: "string" } },
        required: ["url"],
      },
      execute: async ({ url }) =>
        (await cache.getOrLoad(`page:${url}`, () =>
          webLimiter.schedule(async () => {
            await sleep(fetchLatencyMs);
            const doc = CORPUS.find((candidate) => candidate.url === url);
            if (!doc) throw new ToolError("fetch_page", `404 Not Found: ${url}`);
            return { url, title: doc.title, excerpt: doc.body.split(". ")[0] };
          }),
        )) as Page,
    })
    .register<{ text: string }, { saved: boolean }>({
      name: "take_note",
      description: "Save a note to the shared notebook of the research team.",
      parameters: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"],
      },
      execute: async ({ text }, context) => {
        context.notes.push({ requestId: context.requestId, text });
        return { saved: true };
      },
    })
    .register<{ expression: string }, { expression: string; value: number }>({
      name: "calculate",
      description: "Evaluate one binary arithmetic expression, such as `12 * 4`.",
      parameters: {
        type: "object",
        properties: { expression: { type: "string" } },
        required: ["expression"],
      },
      execute: async ({ expression }) => ({ expression, value: evaluate(expression) }),
    });
}
