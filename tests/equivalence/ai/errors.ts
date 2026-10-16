// Errors: HTTP 401 and 500 as APICallError, the retries of a 500 as RetryError, a bad API
// key setting, and prompts and arguments that generateText rejects.
import { generateText } from "ai";
import { createOpenAI, openai } from "@ai-sdk/openai";
import { show } from "./lib/show.ts";

function report(error: any): void {
  console.log(error.name, "|", error.message, "|", error instanceof Error);
  if (error.name !== "AI_APICallError") return;
  console.log(
    "  status",
    error.statusCode,
    "retryable",
    error.isRetryable,
    "url",
    error.url.endsWith("/v1/chat/completions"),
  );
  console.log("  body", error.responseBody);
  console.log("  data", show(error.data));
  console.log("  headers", show(error.responseHeaders));
  console.log("  request", show(error.requestBodyValues));
}

async function attempt(label: string, options: Record<string, unknown>): Promise<void> {
  try {
    const result = await generateText(options as any);
    console.log(label, "succeeded:", result.text);
  } catch (error: any) {
    console.log(label);
    report(error);
    if (error.name !== "AI_RetryError") return;
    console.log(
      "  reason",
      error.reason,
      "attempts",
      error.errors.length,
      error.lastError === error.errors[2],
    );
    for (const each of error.errors) report(each);
  }
}

const wrongKey = createOpenAI({ baseURL: process.env.OPENAI_BASE_URL, apiKey: "sk-wrong" });
await attempt("401", { model: wrongKey.chat("gpt-4o-mini"), prompt: "hi" });
await attempt("500 without retries", {
  model: openai.chat("fake-500"),
  prompt: "hi",
  maxRetries: 0,
});
await attempt("500 with one retry", {
  model: openai.chat("fake-500"),
  prompt: "hi",
  maxRetries: 1,
});
await attempt("500 with default retries", { model: openai.chat("fake-500"), prompt: "hi" });

const badKey = createOpenAI({ baseURL: process.env.OPENAI_BASE_URL, apiKey: 42 as any });
await attempt("api key", { model: badKey.chat("gpt-4o-mini"), prompt: "hi" });

const model = openai.chat("gpt-4o-mini");
await attempt("no prompt", { model });
await attempt("both", { model, prompt: "a", messages: [{ role: "user", content: "b" }] });
await attempt("empty", { model, messages: [] });
await attempt("system message", {
  model,
  messages: [
    { role: "system", content: "s" },
    { role: "user", content: "u" },
  ],
});
await attempt("bad message", { model, messages: [{ role: "robot", content: "beep" }] });
await attempt("bad instructions", {
  model,
  prompt: "a",
  instructions: [{ role: "user", content: "u" }],
});
await attempt("negative retries", { model, prompt: "a", maxRetries: -1 });
await attempt("fractional retries", { model, prompt: "a", maxRetries: 1.5 });
await attempt("fine", { model, prompt: "still works", maxRetries: 2.0 });
