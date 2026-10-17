// The documents that the search and fetch tools serve. In production these come from the
// docs index; the local corpus keeps the service runnable offline.

export interface Doc {
  url: string;
  title: string;
  body: string;
  tags: string[];
}

export const CORPUS: readonly Doc[] = [
  {
    url: "https://docs.example.org/beam/scheduler",
    title: "The BEAM scheduler",
    body: "Each scheduler thread runs a process for a budget of about 4000 reductions, then preempts it, so one busy process cannot starve the others and latency stays low.",
    tags: ["beam", "scheduler", "reductions", "latency"],
  },
  {
    url: "https://docs.example.org/beam/processes",
    title: "Lightweight processes",
    body: "A BEAM process starts with a heap of a few hundred words and has its own garbage collector, so collection pauses one process and never the whole node.",
    tags: ["beam", "processes", "memory"],
  },
  {
    url: "https://docs.example.org/v8/event-loop",
    title: "The event loop",
    body: "The event loop runs one callback at a time. A callback that blocks for 50 ms delays every timer, socket, and promise that is ready behind it.",
    tags: ["node", "event", "loop", "latency"],
  },
  {
    url: "https://docs.example.org/node/timers",
    title: "Timers in Node.js",
    body: "setTimeout schedules a callback after at least the given delay. Timers fire in the timers phase of the event loop, after expired timers are sorted by due time.",
    tags: ["node", "timers", "event", "loop"],
  },
  {
    url: "https://docs.example.org/node/microtasks",
    title: "Microtasks and promises",
    body: "Promise reactions run as microtasks after the current callback and before the event loop moves to its next phase.",
    tags: ["node", "promises", "microtasks"],
  },
  {
    url: "https://docs.example.org/otp/supervisors",
    title: "Supervisors",
    body: "A supervisor restarts its children when they crash. The restart strategy decides which children restart: one_for_one, one_for_all, or rest_for_one.",
    tags: ["otp", "supervisor", "restart", "strategy"],
  },
  {
    url: "https://docs.example.org/otp/pools",
    title: "Worker pools",
    body: "A pool of identical workers fits one_for_one: a crashed worker restarts alone, and the other workers keep their state and their callers.",
    tags: ["otp", "workers", "pool", "strategy"],
  },
];
