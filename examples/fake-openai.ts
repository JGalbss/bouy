import { createHash } from "node:crypto";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { json } from "node:stream/consumers";
import { setTimeout as sleep } from "node:timers/promises";
import { z } from "zod";

const CREATED = 1_767_225_600;

const ROUTE = "POST /v1/chat/completions";

const Content = z
  .union([
    z.string(),
    z
      .array(z.object({ type: z.literal("text"), text: z.string() }))
      .transform((parts) => parts.map((part) => part.text).join("")),
  ])
  .nullish()
  .transform((content) => content ?? "");

const ChatRequest = z.object({
  model: z.string(),
  stream: z.boolean().default(false),
  messages: z
    .array(
      z.object({
        role: z.enum(["system", "developer", "user", "assistant", "tool"]),
        content: Content,
      }),
    )
    .min(1),
  tools: z
    .array(
      z.object({
        type: z.literal("function"),
        function: z.object({
          name: z.string(),
          parameters: z.object({ required: z.array(z.string()).default([]) }),
        }),
      }),
    )
    .default([]),
});

type ChatRequest = z.infer<typeof ChatRequest>;

const ListeningAddress = z.object({ port: z.number() });

interface ToolCall {
  readonly id: string;
  readonly type: "function";
  readonly function: { readonly name: string; readonly arguments: string };
}

interface Delta {
  readonly role?: "assistant";
  readonly content?: string;
  readonly tool_calls?: ReadonlyArray<ToolCall & { readonly index: number }>;
}

interface Completion {
  readonly id: string;
  readonly model: string;
  readonly content: string | null;
  readonly toolCalls: ReadonlyArray<ToolCall>;
  readonly deltas: ReadonlyArray<Delta>;
  readonly finishReason: "stop" | "tool_calls";
  readonly usage: {
    readonly prompt_tokens: number;
    readonly completion_tokens: number;
    readonly total_tokens: number;
  };
}

export interface FakeOpenAIOptions {
  readonly latencyMs?: number;
}

const countWords = (text: string): number => text.split(/\s+/u).filter(Boolean).length;

export class FakeOpenAI {
  readonly baseURL: string;
  readonly #server: Server;
  readonly #latencyMs: number;
  #active = 0;
  #peakConcurrency = 0;
  #served = 0;

  private constructor(server: Server, baseURL: string, latencyMs: number) {
    this.#server = server;
    this.baseURL = baseURL;
    this.#latencyMs = latencyMs;
    server.on("request", (request: IncomingMessage, response: ServerResponse) => {
      void this.#serve(request, response);
    });
  }

  static async start(options: FakeOpenAIOptions = {}): Promise<FakeOpenAI> {
    const server = createServer();
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const { port } = ListeningAddress.parse(server.address());
    return new FakeOpenAI(server, `http://127.0.0.1:${port}/v1`, options.latencyMs ?? 0);
  }

  get served(): number {
    return this.#served;
  }

  get peakConcurrency(): number {
    return this.#peakConcurrency;
  }

  async stop(): Promise<void> {
    const closed = once(this.#server, "close");
    this.#server.close();
    this.#server.closeAllConnections();
    await closed;
  }

  async #serve(request: IncomingMessage, response: ServerResponse): Promise<void> {
    this.#active += 1;
    this.#peakConcurrency = Math.max(this.#peakConcurrency, this.#active);
    try {
      await this.#answer(request, response);
    } finally {
      this.#active -= 1;
    }
  }

  async #answer(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const route = `${request.method} ${request.url}`;
    if (route !== ROUTE) return FakeOpenAI.#reject(response, 404, `There is no route ${route}.`);
    const body = ChatRequest.safeParse(await json(request).catch(() => undefined));
    if (!body.success) return FakeOpenAI.#reject(response, 400, z.prettifyError(body.error));
    await sleep(this.#latencyMs);
    const completion = FakeOpenAI.#complete(body.data);
    this.#served += 1;
    if (body.data.stream) return FakeOpenAI.#sendEvents(response, completion);
    const message = {
      role: "assistant",
      content: completion.content,
      ...(completion.toolCalls.length > 0 && { tool_calls: completion.toolCalls }),
    };
    return FakeOpenAI.#sendJson(
      response,
      200,
      JSON.stringify({
        id: completion.id,
        object: "chat.completion",
        created: CREATED,
        model: completion.model,
        choices: [{ index: 0, message, finish_reason: completion.finishReason }],
        usage: completion.usage,
      }),
    );
  }

  static #complete(request: ChatRequest): Completion {
    const question = request.messages.findLast((message) => message.role === "user")?.content ?? "";
    const last = request.messages.at(-1);
    const digest = createHash("sha256")
      .update(JSON.stringify(request.messages))
      .digest("hex")
      .slice(0, 16);
    const [tool] = request.tools;
    const promptTokens = request.messages.reduce(
      (total, message) => total + countWords(message.content),
      0,
    );
    const base = { id: `chatcmpl-${digest}`, model: request.model };
    if (tool === undefined || last?.role === "tool") {
      const evidence = last?.role === "tool" ? ` The tool returned ${last.content}` : "";
      const text = `Answer about "${question}".${evidence}`;
      const words = text.split(/(?<= )/u);
      return {
        ...base,
        content: text,
        toolCalls: [],
        deltas: words.map((word, index) => ({
          ...(index === 0 && { role: "assistant" as const }),
          content: word,
        })),
        finishReason: "stop",
        usage: FakeOpenAI.#usage(promptTokens, words.length),
      };
    }
    const input = Object.fromEntries(
      tool.function.parameters.required.map((key) => [key, question]),
    );
    const call: ToolCall = {
      id: `call_${digest}`,
      type: "function",
      function: { name: tool.function.name, arguments: JSON.stringify(input) },
    };
    return {
      ...base,
      content: null,
      toolCalls: [call],
      deltas: [{ role: "assistant", tool_calls: [{ index: 0, ...call }] }],
      finishReason: "tool_calls",
      usage: FakeOpenAI.#usage(promptTokens, countWords(call.function.arguments)),
    };
  }

  static #usage(promptTokens: number, completionTokens: number): Completion["usage"] {
    return {
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      total_tokens: promptTokens + completionTokens,
    };
  }

  static #sendEvents(response: ServerResponse, completion: Completion): void {
    const chunk = {
      id: completion.id,
      object: "chat.completion.chunk",
      created: CREATED,
      model: completion.model,
    };
    const events = [
      ...completion.deltas.map((delta) => ({
        ...chunk,
        choices: [{ index: 0, delta, finish_reason: null }],
      })),
      { ...chunk, choices: [{ index: 0, delta: {}, finish_reason: completion.finishReason }] },
      { ...chunk, choices: [], usage: completion.usage },
    ];
    response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`);
    response.end("data: [DONE]\n\n");
  }

  static #reject(response: ServerResponse, status: number, message: string): void {
    const error = { message, type: "invalid_request_error", param: null, code: null };
    FakeOpenAI.#sendJson(response, status, JSON.stringify({ error }));
  }

  static #sendJson(response: ServerResponse, status: number, body: string): void {
    response.writeHead(status, { "content-type": "application/json" }).end(body);
  }
}
