import { shutdown, spawn } from "bouy";
import { FakeOpenAI } from "../../examples/fake-openai.ts";
import { canonicalJson, runScenario, type Report } from "./npm-scenario.ts";

const ACTORS = 3;

class Scenario {
  run(baseURL: string): Promise<Report> {
    return runScenario(baseURL);
  }
}

const llm = await FakeOpenAI.start();
const scenarios = Array.from({ length: ACTORS }, () => spawn(Scenario));
const reports = await Promise.all(scenarios.map((scenario) => scenario.run(llm.baseURL)));
const outputs = new Set(reports.map(canonicalJson));
if (outputs.size !== 1)
  throw new Error(`${ACTORS} actors produced ${outputs.size} different reports`);
console.log([...outputs].join(""));
await shutdown();
await llm.stop();
