import { AgentError, ToolError } from "../errors.ts";
import type { ToolContext, ToolRegistry } from "../tools/registry.ts";
import { BaseAgent, type AgentDeps } from "./base-agent.ts";
import {
  extractUrls,
  firstSentences,
  parsePlan,
  parseToolResults,
  type PlanStep,
  type StepKind,
  type ToolOutput,
} from "./parse.ts";
import { pinnedCallsFor, Prompts } from "./prompts.ts";

export interface Finding {
  requestId: string;
  step: number;
  kind: StepKind;
  argument: string;
  outputs: ToolOutput[];
  sources: string[];
  model: string;
  attempts: number;
  usedFallback: boolean;
}

export class PlannerAgent extends BaseAgent {
  get role(): string {
    return "planner";
  }

  protected get system(): string {
    return Prompts.PLANNER;
  }

  async plan(topic: string, outline: readonly string[]): Promise<PlanStep[]> {
    const completion = await this.complete(Prompts.plan(topic, outline));
    const steps = parsePlan(completion.text);
    if (steps.length === 0) {
      throw new AgentError(`no steps in the plan for "${topic}"`, "EMPTY_PLAN");
    }
    this.logger.debug("plan parsed", { steps: steps.length });
    return steps;
  }
}

export class ResearchWorker extends BaseAgent {
  static readonly TOOLS = ["search", "fetch_page", "take_note", "calculate"] as const;

  constructor(
    name: string,
    model: string,
    deps: AgentDeps,
    private readonly registry: ToolRegistry,
  ) {
    super(name, model, deps);
  }

  get role(): string {
    return "researcher";
  }

  protected get system(): string {
    return Prompts.RESEARCHER;
  }

  override describe(): string {
    return `${super.describe()} with ${ResearchWorker.TOOLS.length} tools`;
  }

  async research(step: PlanStep, context: ToolContext): Promise<Finding> {
    const calls = pinnedCallsFor(step);
    const tools = this.registry.forModel(ResearchWorker.TOOLS, context);
    const completion = await this.complete(Prompts.research(step, calls), {
      tools,
      maxSteps: calls.length + 1,
    });

    // A failed tool call fails the step: a partial answer would read as a complete one.
    const [failed] = completion.toolErrors;
    if (failed) {
      throw failed.error instanceof Error
        ? failed.error
        : new ToolError(failed.toolName, String(failed.error));
    }

    return {
      requestId: context.requestId,
      step: step.index,
      kind: step.kind,
      argument: step.argument,
      outputs: parseToolResults(completion.text),
      sources: extractUrls(completion.text),
      model: completion.model,
      attempts: completion.attempts,
      usedFallback: completion.usedFallback,
    };
  }
}

export class SummaryWorker extends BaseAgent {
  constructor(
    name: string,
    model: string,
    deps: AgentDeps,
    private readonly maxSentences = 2,
  ) {
    super(name, model, deps);
  }

  get role(): string {
    return "summarizer";
  }

  protected get system(): string {
    return Prompts.SUMMARIZER;
  }

  async summarize(topic: string, findings: readonly Finding[]): Promise<string> {
    if (findings.length === 0) {
      throw new AgentError(`nothing to summarize for "${topic}"`, "NO_FINDINGS");
    }
    const lines = findings.map(
      (finding) =>
        `${finding.kind} ${finding.argument}: ${finding.outputs.map((o) => o.tool).join(", ")}`,
    );
    const completion = await this.complete(Prompts.summarize(topic, lines));
    return firstSentences(completion.text, this.maxSentences);
  }
}
