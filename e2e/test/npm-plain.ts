import { FakeOpenAI } from "../../examples/fake-openai.ts";
import { canonicalJson, runScenario } from "./npm-scenario.ts";

const llm = await FakeOpenAI.start();
console.log(canonicalJson(await runScenario(llm.baseURL)));
await llm.stop();
