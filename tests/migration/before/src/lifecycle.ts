import type { Logger } from "./logger.ts";

export interface Heartbeat {
  readonly beats: number;
  stop(): void;
}

/** Calls `onBeat` every `intervalMs` without keeping the process alive. */
export function startHeartbeat(intervalMs: number, onBeat: (beat: number) => void): Heartbeat {
  let beats = 0;
  const timer = setInterval(() => {
    beats++;
    onBeat(beats);
  }, intervalMs);
  timer.unref();
  return {
    get beats() {
      return beats;
    },
    stop() {
      clearInterval(timer);
    },
  };
}

export interface Closable {
  readonly name: string;
  close(): Promise<void>;
}

const SIGNAL_EXIT_CODES: Partial<Record<NodeJS.Signals, number>> = { SIGINT: 130, SIGTERM: 143 };

/**
 * Closes `resources` in reverse order of creation on SIGINT, on SIGTERM, or when the returned
 * function is called. Closing happens once.
 */
export function installShutdownHooks(logger: Logger, resources: Closable[]): () => Promise<void> {
  let closing: Promise<void> | undefined;

  const shutdown = (reason: string): Promise<void> => {
    closing ??= (async () => {
      logger.info("shutting down", { reason });
      for (const resource of resources.reverse()) {
        await resource.close().catch((error: unknown) => {
          logger.error("close failed", { resource: resource.name, error });
        });
      }
      logger.info("closed", { resources: resources.map((resource) => resource.name).join(",") });
    })();
    return closing;
  };

  const onSignal = (signal: NodeJS.Signals): void => {
    shutdown(signal).finally(() => process.exit(SIGNAL_EXIT_CODES[signal] ?? 1));
  };

  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  process.on("unhandledRejection", (reason) => {
    logger.error("unhandled rejection", { reason: String(reason) });
    process.exitCode = 1;
  });
  process.on("exit", (code) => {
    logger.info("process exit", { code });
  });

  return () => shutdown("finished");
}
