import type { TtlCache } from "../cache.ts";
import { describeError } from "../errors.ts";
import type { Logger } from "../logger.ts";
import { Priority, type JobQueue } from "../queue.ts";
import type { Page } from "../tools/builtin.ts";
import type { Note, ToolContext } from "../tools/registry.ts";
import type { PlanStep, StepKind } from "./parse.ts";
import type { Finding, PlannerAgent, ResearchWorker, SummaryWorker } from "./workers.ts";

export interface ResearchRequest {
  id: string;
  topic: string;
  priority: Priority;
  outline: string[];
  /** Pins the research steps of this request to one model. */
  workerModel?: string;
}

export type RequestStatus = "complete" | "partial" | "failed";

export interface StepFailure {
  step: number;
  kind: StepKind | "plan";
  error: string;
}

export interface RequestOutcome {
  request: ResearchRequest;
  status: RequestStatus;
  plan: PlanStep[];
  findings: Finding[];
  failures: StepFailure[];
  summary: string;
  citations: string[];
}

export interface CoordinatorDeps {
  logger: Logger;
  queue: JobQueue;
  planner: PlannerAgent;
  summarizer: SummaryWorker;
  createWorker: (model: string) => ResearchWorker;
  defaultWorkerModel: string;
  pageCache: TtlCache<string, unknown>;
}

/**
 * Runs research requests in three phases: plan each request, run every research step of
 * every request on the shared job queue, then summarize each request.
 */
export class Coordinator {
  readonly #notebook: Note[] = [];
  readonly #workers = new Map<string, ResearchWorker>();

  constructor(private readonly deps: CoordinatorDeps) {}

  get notebook(): readonly Note[] {
    return this.#notebook;
  }

  get workers(): ResearchWorker[] {
    return [...this.#workers.values()];
  }

  async run(requests: ResearchRequest[]): Promise<RequestOutcome[]> {
    const outcomes: RequestOutcome[] = [];
    for (const request of requests) {
      normalizeRequest(request);
      outcomes.push(await this.plan(request));
    }

    const steps: Promise<void>[] = [];
    outcomes.forEach((outcome) => {
      if (outcome.status !== "failed") steps.push(...this.dispatch(outcome));
    });
    this.deps.logger.info("research steps queued", {
      steps: steps.length,
      concurrency: this.deps.queue.concurrency,
    });
    await Promise.all(steps);

    for (const outcome of outcomes) {
      if (outcome.status === "failed") continue;
      await this.summarize(outcome);
    }
    return outcomes;
  }

  private async plan(request: ResearchRequest): Promise<RequestOutcome> {
    const log = this.deps.logger.child({ request: request.id });
    const outcome: RequestOutcome = {
      request,
      status: "complete",
      plan: [],
      findings: [],
      failures: [],
      summary: "",
      citations: [],
    };
    log.info("planning", { topic: request.topic, priority: Priority[request.priority] });
    try {
      outcome.plan = await this.deps.planner.plan(request.topic, request.outline);
      log.info("planned", {
        steps: outcome.plan.map((step) => `${step.index}:${step.kind}`).join(" "),
      });
    } catch (error) {
      outcome.status = "failed";
      outcome.failures.push({ step: 0, kind: "plan", error: describeError(error) });
      log.error("planning failed", { error });
    }
    return outcome;
  }

  private dispatch(outcome: RequestOutcome): Promise<void>[] {
    const { request } = outcome;
    const worker = this.workerFor(request.workerModel ?? this.deps.defaultWorkerModel);
    const context: ToolContext = {
      requestId: request.id,
      notes: this.#notebook,
      logger: this.deps.logger.child({ request: request.id }),
    };

    return outcome.plan
      .filter((step) => step.kind !== "summarize")
      .map((step) =>
        this.deps.queue
          .add(
            `${request.id}#${step.index}`,
            () => worker.research(step, context),
            request.priority,
          )
          .then((finding) => {
            outcome.findings.push(finding);
          })
          .catch((error: unknown) => {
            outcome.status = "partial";
            outcome.failures.push({
              step: step.index,
              kind: step.kind,
              error: describeError(error),
            });
          }),
      );
  }

  private async summarize(outcome: RequestOutcome): Promise<void> {
    const log = this.deps.logger.child({ request: outcome.request.id });
    // Steps finish in any order; report them in plan order.
    outcome.findings.sort((a, b) => a.step - b.step);
    outcome.failures.sort((a, b) => a.step - b.step);
    outcome.citations = this.cite(outcome.findings);
    try {
      outcome.summary = await this.deps.summarizer.summarize(
        outcome.request.topic,
        outcome.findings,
      );
    } catch (error) {
      outcome.status = "partial";
      outcome.failures.push({ step: 0, kind: "summarize", error: describeError(error) });
    }
    log.info("summarized", {
      status: outcome.status,
      findings: outcome.findings.length,
      failures: outcome.failures.length,
    });
  }

  /** The title of each cited page that a step fetched, else its URL. */
  private cite(findings: Finding[]): string[] {
    const citations: string[] = [];
    findings.forEach((finding) => {
      finding.sources.forEach((url) => {
        const page = this.deps.pageCache.get(`page:${url}`) as Page | undefined;
        citations.push(page ? `${page.title} <${url}>` : url);
      });
    });
    return [...new Set(citations)];
  }

  private workerFor(model: string): ResearchWorker {
    let worker = this.#workers.get(model);
    if (!worker) {
      worker = this.deps.createWorker(model);
      this.#workers.set(model, worker);
    }
    return worker;
  }
}

/** Cleans up a request as users type it: stray whitespace and empty outline lines. */
function normalizeRequest(request: ResearchRequest): void {
  request.topic = request.topic.trim().replace(/\s+/g, " ");
  request.outline = request.outline.map((line) => line.trim()).filter((line) => line.length > 0);
}
