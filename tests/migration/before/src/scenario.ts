import type { ResearchRequest } from "./agents/coordinator.ts";
import type { ConfigOverrides } from "./config.ts";
import { Priority } from "./queue.ts";

export interface Scenario {
  name: string;
  description: string;
  /** Applied on top of the defaults file and the environment. */
  settings: ConfigOverrides;
  requests: ResearchRequest[];
}

const DOCS = "https://docs.example.org";

export const scenarios: Record<string, Scenario> = {
  default: {
    name: "default",
    description: "Four requests: a clean run, a failing step, a model outage, and a bad plan",
    // Two workers, so that the priority order of the queue shows in the start order.
    settings: { concurrency: 2 },
    requests: [
      {
        id: "req-1",
        topic: "  How does the BEAM scheduler   keep latency low? ",
        priority: Priority.Normal,
        outline: ["search: beam scheduler reductions", "calc: 4000 * 2", "summarize: findings"],
      },
      {
        id: "req-2",
        topic: "How do Node timers interact with the event loop?",
        priority: Priority.High,
        outline: [
          "search: node event loop timers",
          `fetch: ${DOCS}/v8/event-loop ${DOCS}/node/timers ${DOCS}/node/microtasks`,
          "",
          "calc: 16 / 0",
          "summarize: findings",
        ],
      },
      {
        id: "req-3",
        topic: "Which OTP restart strategy fits a worker pool?",
        priority: Priority.Low,
        outline: ["search: otp restart strategy pool", "summarize: findings"],
        // The fake server answers HTTP 500 for this model: retries, then the fallback model.
        workerModel: "fake-500",
      },
      {
        id: "req-4",
        topic: "Draft a tweet about actors",
        priority: Priority.Low,
        outline: [],
      },
    ],
  },
};
