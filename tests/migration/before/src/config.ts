import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Schema } from "effect";

const here = dirname(fileURLToPath(import.meta.url));
export const DEFAULTS_PATH = join(here, "..", "config", "defaults.json");

const ConfigSchema = Schema.Struct({
  service: Schema.String,
  logLevel: Schema.Literals(["debug", "info", "warn", "error"]),
  models: Schema.Struct({
    planner: Schema.String,
    worker: Schema.String,
    summarizer: Schema.String,
    fallback: Schema.String,
  }),
  queue: Schema.Struct({ concurrency: Schema.Number, jobTimeoutMs: Schema.Number }),
  retry: Schema.Struct({
    retries: Schema.Number,
    baseDelayMs: Schema.Number,
    maxDelayMs: Schema.Number,
  }),
  rateLimit: Schema.Struct({ capacity: Schema.Number, refillEveryMs: Schema.Number }),
  cache: Schema.Struct({ ttlMs: Schema.Number, maxEntries: Schema.Number }),
  heartbeatMs: Schema.Number,
});

export type Config = typeof ConfigSchema.Type;

const decodeConfig = Schema.decodeUnknownSync(ConfigSchema);

export interface ConfigOverrides {
  concurrency?: number;
  logLevel?: string;
  workerModel?: string;
}

export interface LoadConfigOptions {
  path?: string;
  env?: Record<string, string | undefined>;
  overrides?: ConfigOverrides;
}

type RawConfig = Record<string, any>;

/** Defaults file, then environment variables, then command-line overrides. */
export async function loadConfig(options: LoadConfigOptions = {}): Promise<Config> {
  const text = await readFile(options.path ?? DEFAULTS_PATH, "utf8");
  const raw: RawConfig = JSON.parse(text);
  applyEnv(raw, options.env ?? {});
  applyOverrides(raw, options.overrides ?? {});
  try {
    return decodeConfig(raw);
  } catch (error) {
    throw new Error(`invalid configuration: ${(error as Error).message}`, { cause: error });
  }
}

function applyEnv(raw: RawConfig, env: Record<string, string | undefined>): void {
  if (env.RESEARCH_LOG_LEVEL) raw.logLevel = env.RESEARCH_LOG_LEVEL;
  if (env.RESEARCH_WORKER_MODEL) raw.models.worker = env.RESEARCH_WORKER_MODEL;
  if (env.RESEARCH_CONCURRENCY) raw.queue.concurrency = Number(env.RESEARCH_CONCURRENCY);
}

function applyOverrides(raw: RawConfig, overrides: ConfigOverrides): void {
  if (overrides.concurrency !== undefined) raw.queue.concurrency = overrides.concurrency;
  if (overrides.logLevel !== undefined) raw.logLevel = overrides.logLevel;
  if (overrides.workerModel !== undefined) raw.models.worker = overrides.workerModel;
}

export function describeConfig(config: Config): string {
  const { models, queue, retry, rateLimit } = config;
  return [
    `service=${config.service}`,
    `log=${config.logLevel}`,
    `models=${models.planner}/${models.worker}/${models.summarizer}`,
    `fallback=${models.fallback}`,
    `concurrency=${queue.concurrency}`,
    `retries=${retry.retries}`,
    `web=${rateLimit.capacity}/${rateLimit.refillEveryMs}ms`,
  ].join(" ");
}
