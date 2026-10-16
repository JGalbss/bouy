import { createOpenAI } from "@ai-sdk/openai";
import { generateText, isStepCount, streamText, tool } from "ai";
import { z } from "zod";

const Order = z.object({
  id: z.string().min(1),
  quantity: z.number().int().positive(),
  tags: z.array(z.string()).default([]),
});

const VALID_ORDER = { id: "order-1", quantity: 2 };
const INVALID_ORDER = { id: "", quantity: -1, tags: "rush" };

const weather = tool({
  description: "Look up the weather for a city.",
  inputSchema: z.object({ city: z.string() }),
  execute: async ({ city }) => ({ city, forecast: `sunny in ${city}` }),
});

export const runScenario = async (baseURL: string) => {
  const parseFailure = (() => {
    try {
      Order.parse(INVALID_ORDER);
      return { threw: false, isZodError: false, issues: [] };
    } catch (error) {
      return {
        threw: true,
        isZodError: error instanceof z.ZodError,
        issues: error instanceof z.ZodError ? error.issues : [],
      };
    }
  })();
  const safeSuccess = Order.safeParse(VALID_ORDER);
  const safeFailure = Order.safeParse(INVALID_ORDER);

  const model = createOpenAI({ baseURL, apiKey: "test" }).chat("gpt-5");

  const generated = await generateText({ model, prompt: "What is an actor?" });

  const streamed = streamText({ model, prompt: "Explain supervision trees." });
  const chunks: Array<string> = [];
  for await (const chunk of streamed.textStream) chunks.push(chunk);

  const withTool = await generateText({
    model,
    prompt: "Lisbon",
    tools: { weather },
    stopWhen: isStepCount(2),
  });

  const streamedWithTool = streamText({
    model,
    prompt: "Oslo",
    tools: { weather },
    stopWhen: isStepCount(2),
  });
  const streamedSteps = await streamedWithTool.steps;

  return {
    zod: {
      parse: Order.parse(VALID_ORDER),
      parseFailure,
      safeParse: { success: safeSuccess.success, data: safeSuccess.data },
      safeParseFailure: { success: safeFailure.success, issues: safeFailure.error?.issues ?? [] },
    },
    generateText: {
      text: generated.text,
      finishReason: generated.finishReason,
      usage: generated.usage,
      warnings: generated.warnings,
      response: {
        id: generated.response.id,
        modelId: generated.response.modelId,
        timestamp: generated.response.timestamp,
      },
    },
    streamText: {
      chunks,
      text: await streamed.text,
      finishReason: await streamed.finishReason,
      usage: await streamed.usage,
    },
    generateTextToolCall: {
      text: withTool.text,
      finishReason: withTool.finishReason,
      steps: withTool.steps.map((step) => ({
        finishReason: step.finishReason,
        toolCalls: step.toolCalls.map(({ toolCallId, toolName, input }) => ({
          toolCallId,
          toolName,
          input,
        })),
        toolResults: step.toolResults.map(({ toolCallId, toolName, output }) => ({
          toolCallId,
          toolName,
          output,
        })),
      })),
    },
    streamTextToolCall: {
      text: await streamedWithTool.text,
      steps: streamedSteps.map((step) => ({
        finishReason: step.finishReason,
        toolCalls: step.toolCalls.map(({ toolName, input }) => ({ toolName, input })),
        toolResults: step.toolResults.map(({ toolName, output }) => ({ toolName, output })),
      })),
    },
  };
};

export type Report = Awaited<ReturnType<typeof runScenario>>;

export const canonicalJson = (report: Report): string =>
  JSON.stringify(report, (_key, value) => {
    if (Object(value) !== value || Array.isArray(value)) return value;
    return Object.fromEntries(
      Object.entries(value).toSorted(([left], [right]) => (left < right ? -1 : 1)),
    );
  });
