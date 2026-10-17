import { BaseAgent } from "./agents/base-agent.ts";
import type { RequestOutcome } from "./agents/coordinator.ts";
import type { Finding } from "./agents/workers.ts";
import type { App } from "./app.ts";
import { Priority, type Job } from "./queue.ts";

export namespace Format {
  export const INDENT = "   ";

  export function label(name: string, width = 10): string {
    return `${INDENT}${name.padEnd(width)}`;
  }

  export function list(items: readonly string[], separator = ", "): string {
    return items.length === 0 ? "(none)" : items.join(separator);
  }

  export function truncate(text: string, max = 100): string {
    const flat = text.replace(/\s+/g, " ").trim();
    return flat.length <= max ? flat : `${flat.slice(0, max - 3)}...`;
  }

  export function percent(ratio: number): string {
    return `${(ratio * 100).toFixed(1)}%`;
  }

  export function pairs(record: object): string {
    return Object.entries(record)
      .map(([key, value]) => `${key}=${value}`)
      .join(" ");
  }
}

/** The record that the report service receives for one request. */
export function toReportInput(outcome: RequestOutcome): Record<string, unknown> {
  return {
    requestId: outcome.request.id,
    topic: outcome.request.topic,
    status: outcome.status,
    summary: outcome.summary,
    findings: outcome.findings.length,
    citations: outcome.citations,
  };
}

type Print = (line: string) => void;

export function printTranscript(
  app: App,
  outcomes: readonly RequestOutcome[],
  published: readonly string[],
  print: Print = console.log,
): void {
  print("== requests ==");
  outcomes.forEach((outcome) => printOutcome(outcome, print));

  print("== queue ==");
  const jobsById = new Map<string, Job>(app.queue.jobs.map((job) => [job.id, job]));
  const started = app.queue.startOrder.map((id) => {
    const job = jobsById.get(id)!;
    return `${id}(${job.name},${Priority[job.priority]})`;
  });
  print(`${Format.label("started")}${started.join(" ")}`);
  print(
    `${Format.label("statuses")}${app.queue.jobs.map((job) => `${job.id}=${job.status}`).join(" ")}`,
  );
  print(`${Format.label("counters")}${Format.pairs(app.metrics.snapshot())}`);

  print("== tools ==");
  for (const tool of app.registry) {
    print(`${Format.label(tool.name, 12)}${app.registry.callCount(tool.name)} calls`);
  }
  const { hits, misses, size } = app.cache.stats;
  const keys = [...app.cache].map(([key]) => key).sort();
  print(
    `${Format.label("cache", 12)}hits=${hits} misses=${misses} size=${size} hit rate ${Format.percent(app.cache.hitRate)}`,
  );
  print(`${Format.label("cached", 12)}${Format.list(keys)}`);
  print(
    `${Format.label("web limit", 12)}acquired=${app.webLimiter.acquired} throttled=${app.webLimiter.throttled}`,
  );

  print("== notebook ==");
  const notes = app.coordinator.notebook.map((note) => `${note.requestId}: ${note.text}`).sort();
  notes.forEach((note) => print(`${Format.INDENT}${note}`));

  print("== agents ==");
  const agents: BaseAgent[] = [app.planner, ...app.coordinator.workers, app.summarizer];
  agents.forEach((agent) => print(`${Format.INDENT}${agent.describe()}`));
  print(`${Format.INDENT}${BaseAgent.instances} agents, ${Format.pairs(app.metrics.usage)}`);

  print("== reports ==");
  published.forEach((line) => print(`${Format.INDENT}${line}`));
  print(`${Format.INDENT}heartbeat ${app.heartbeat.beats > 0 ? "alive" : "silent"}`);
}

function printOutcome(outcome: RequestOutcome, print: Print): void {
  const { request } = outcome;
  print(`-- ${request.id} [${Priority[request.priority]}] ${request.topic}: ${outcome.status}`);
  if (outcome.plan.length > 0) {
    print(
      `${Format.label("plan")}${outcome.plan.map((step) => `${step.index}.${step.kind}`).join(" ")}`,
    );
  }
  const findings = new Map<number, Finding>(
    outcome.findings.map((finding) => [finding.step, finding]),
  );
  for (const step of outcome.plan) {
    if (step.kind === "summarize") continue;
    const finding = findings.get(step.index);
    if (!finding) continue;
    const via = finding.usedFallback
      ? `${finding.model} (fallback after ${finding.attempts} attempts)`
      : `${finding.model} (${finding.attempts} attempt${finding.attempts === 1 ? "" : "s"})`;
    print(`${Format.label(`step ${step.index}`)}${step.kind} via ${via}`);
    finding.outputs.forEach((output) => {
      print(`${Format.label("")}${output.tool} -> ${Format.truncate(output.output, 90)}`);
    });
  }
  outcome.failures.forEach((failure) => {
    print(
      `${Format.label(failure.step === 0 ? failure.kind : `step ${failure.step}`)}FAILED ${failure.error}`,
    );
  });
  if (outcome.summary) print(`${Format.label("summary")}${Format.truncate(outcome.summary, 140)}`);
  if (outcome.citations.length > 0) {
    print(`${Format.label("sources")}${Format.list(outcome.citations, " | ")}`);
  }
}
