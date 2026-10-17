import type { AgentDeps } from "./agents/base-agent.ts";
import { Coordinator } from "./agents/coordinator.ts";
import { PlannerAgent, ResearchWorker, SummaryWorker } from "./agents/workers.ts";
import { TtlCache } from "./cache.ts";
import type { Config } from "./config.ts";
import { startHeartbeat, type Closable, type Heartbeat } from "./lifecycle.ts";
import { Logger } from "./logger.ts";
import { Metrics } from "./metrics.ts";
import { JobQueue } from "./queue.ts";
import { TokenBucket } from "./rate-limiter.ts";
import { registerBuiltinTools } from "./tools/builtin.ts";
import { ToolRegistry } from "./tools/registry.ts";

export interface App {
  config: Config;
  logger: Logger;
  metrics: Metrics;
  cache: TtlCache<string, unknown>;
  webLimiter: TokenBucket;
  queue: JobQueue;
  registry: ToolRegistry;
  planner: PlannerAgent;
  summarizer: SummaryWorker;
  coordinator: Coordinator;
  heartbeat: Heartbeat;
  /** In creation order. Shutdown closes them in reverse. */
  resources: Closable[];
}

export interface AppOptions {
  clock?: () => number;
  fetchLatencyMs?: number;
}

export function createApp(config: Config, options: AppOptions = {}): App {
  const logger = Logger.configure({
    level: Logger.parseLevel(config.logLevel),
    clock: options.clock,
    bindings: { service: config.service },
  });
  const metrics = new Metrics();
  const cache = new TtlCache<string, unknown>("tools", config.cache.ttlMs, config.cache.maxEntries);
  const webLimiter = new TokenBucket(config.rateLimit);
  const queue = new JobQueue({
    concurrency: config.queue.concurrency,
    timeoutMs: config.queue.jobTimeoutMs,
  });
  const registry = registerBuiltinTools(ToolRegistry.shared, {
    cache,
    webLimiter,
    fetchLatencyMs: options.fetchLatencyMs ?? 15,
  });
  const stopWatching = metrics.watch(queue);

  const agentDeps: AgentDeps = {
    logger,
    retry: config.retry,
    fallbackModel: config.models.fallback,
    usage: metrics.usage,
  };
  const planner = new PlannerAgent("planner-1", config.models.planner, agentDeps);
  const summarizer = new SummaryWorker("summarizer-1", config.models.summarizer, agentDeps);
  const coordinator = new Coordinator({
    logger,
    queue,
    planner,
    summarizer,
    createWorker: (model) => new ResearchWorker(`researcher-${model}`, model, agentDeps, registry),
    defaultWorkerModel: config.models.worker,
    pageCache: cache,
  });

  const heartbeat = startHeartbeat(config.heartbeatMs, (beat) => {
    logger.debug("heartbeat", { beat, running: queue.running, pending: queue.pending });
  });

  const resources: Closable[] = [
    { name: "heartbeat", close: async () => heartbeat.stop() },
    { name: "web-limiter", close: async () => webLimiter.dispose() },
    { name: "queue", close: () => queue.close() },
    { name: "metrics", close: async () => stopWatching() },
  ];

  return {
    config,
    logger,
    metrics,
    cache,
    webLimiter,
    queue,
    registry,
    planner,
    summarizer,
    coordinator,
    heartbeat,
    resources,
  };
}
