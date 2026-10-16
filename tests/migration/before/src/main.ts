// research-assistant: runs a scripted research scenario against the configured models and
// prints a transcript.
//
//   OPENAI_BASE_URL=http://127.0.0.1:8080/v1 OPENAI_API_KEY=... \
//     node --experimental-transform-types src/main.ts [scenario] [options]
import { createApp } from "./app.ts";
import { describeConfig, loadConfig, type ConfigOverrides } from "./config.ts";
import { installShutdownHooks } from "./lifecycle.ts";
import { publishReports } from "./reports/report-service.ts";
import { scenarios } from "./scenario.ts";
import { printTranscript, toReportInput } from "./transcript.ts";

const USAGE =
  "usage: research-assistant [scenario] [--concurrency N] [--log-level LEVEL] [--worker-model ID]";

interface CliOptions {
  scenario: string;
  overrides: ConfigOverrides;
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { scenario: "default", overrides: {} };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--concurrency":
        options.overrides.concurrency = Number(argv[++i]);
        break;
      case "--log-level":
        options.overrides.logLevel = argv[++i];
        break;
      case "--worker-model":
        options.overrides.workerModel = argv[++i];
        break;
      case "-h":
      case "--help":
        console.log(USAGE);
        process.exit(0);
      default:
        if (arg.startsWith("-")) throw new Error(`unknown option ${arg}\n${USAGE}`);
        options.scenario = arg;
    }
  }
  return options;
}

/** Advances one second per reading, so that log timestamps are the same on every run. */
function steppingClock(start: string, stepMs = 1_000): () => number {
  let now = Date.parse(start);
  return () => (now += stepMs);
}

async function main(argv: string[]): Promise<void> {
  const cli = parseArgs(argv);
  const scenario = scenarios[cli.scenario];
  if (!scenario) {
    throw new Error(
      `unknown scenario "${cli.scenario}", expected one of: ${Object.keys(scenarios)}`,
    );
  }

  const config = await loadConfig({
    env: process.env,
    overrides: { ...scenario.settings, ...cli.overrides },
  });
  const app = createApp(config, { clock: steppingClock("2026-01-01T09:00:00.000Z") });
  const shutdown = installShutdownHooks(app.logger, app.resources);

  console.log(`== ${config.service}: ${scenario.description} ==`);
  console.log(describeConfig(config));
  app.logger.info("starting", { scenario: scenario.name, requests: scenario.requests.length });

  const outcomes = await app.coordinator.run(scenario.requests);
  const published = await publishReports(outcomes.map(toReportInput));
  printTranscript(app, outcomes, published);
  await shutdown();
}

main(process.argv.slice(2)).catch((error: unknown) => {
  console.error("fatal:", error);
  process.exit(1);
});
