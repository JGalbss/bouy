import { openai } from "@ai-sdk/openai";
import { APICallError, generateText, stepCountIs, type Tool } from "ai";
import { memoize } from "../cache.ts";
import { ModelUnavailableError } from "../errors.ts";
import type { Logger } from "../logger.ts";
import { addUsage, type UsageTotals } from "../metrics.ts";
import { retry, type RetryOptions } from "../util/async.ts";

// One provider model object per model id.
export const modelFor = memoize((id: string) => openai.chat(id));

export interface AgentDeps {
  logger: Logger;
  retry: RetryOptions;
  fallbackModel: string;
  /** Shared with the metrics, so every agent adds to one total. */
  usage: UsageTotals;
}

export interface CompletionOptions {
  tools?: Record<string, Tool>;
  maxSteps?: number;
}

export interface Completion {
  text: string;
  model: string;
  attempts: number;
  usedFallback: boolean;
  steps: number;
  toolErrors: ToolFailure[];
}

export interface ToolFailure {
  toolName: string;
  error: unknown;
}

export function isRetryable(error: unknown): boolean {
  return APICallError.isInstance(error) && error.isRetryable;
}

export abstract class BaseAgent {
  static #instances = 0;

  protected readonly logger: Logger;

  constructor(
    readonly name: string,
    protected readonly model: string,
    protected readonly deps: AgentDeps,
  ) {
    BaseAgent.#instances++;
    this.logger = deps.logger.child({ agent: name });
  }

  static get instances(): number {
    return BaseAgent.#instances;
  }

  abstract get role(): string;

  protected abstract get system(): string;

  describe(): string {
    return `${this.role} ${this.name} on ${this.model}`;
  }

  /**
   * Calls the primary model with retries. When it stays unavailable, makes one call to the
   * fallback model.
   */
  protected async complete(prompt: string, options: CompletionOptions = {}): Promise<Completion> {
    let attempts = 0;
    const call = (model: string) =>
      generateText({
        model: modelFor(model),
        system: this.system,
        prompt,
        tools: options.tools,
        stopWhen: stepCountIs(options.maxSteps ?? 1),
        maxRetries: 0,
      });

    const primary = retry(
      () => {
        attempts++;
        return call(this.model);
      },
      {
        ...this.deps.retry,
        shouldRetry: isRetryable,
        onRetry: (error, attempt) =>
          this.logger.debug("retrying model call", { attempt, error: String(error) }),
      },
    );

    const outcome = await primary
      .then((result) => ({ result, model: this.model, usedFallback: false }))
      .catch((error: unknown) => {
        if (!isRetryable(error)) throw error;
        this.logger.warn("primary model unavailable, using fallback", {
          model: this.model,
          fallback: this.deps.fallbackModel,
          attempts,
          error: error instanceof Error ? error.message : String(error),
        });
        return call(this.deps.fallbackModel)
          .then((result) => ({ result, model: this.deps.fallbackModel, usedFallback: true }))
          .catch((fallbackError: unknown) => {
            throw new ModelUnavailableError(this.model, attempts + 1, { cause: fallbackError });
          });
      });

    addUsage(this.deps.usage, outcome.result.totalUsage);
    return {
      text: outcome.result.text,
      model: outcome.model,
      attempts,
      usedFallback: outcome.usedFallback,
      steps: outcome.result.steps.length,
      toolErrors: outcome.result.steps.flatMap((step) =>
        step.content.flatMap((part) =>
          part.type === "tool-error" ? [{ toolName: part.toolName, error: part.error }] : [],
        ),
      ),
    };
  }
}
