// From the README of langchain: an agent that calls a tool, with the fake tool-calling
// model that langchain exports for tests.
import { FakeToolCallingModel, createAgent, tool } from "langchain";

const weather = tool(async ({ city }) => `It is sunny in ${city}.`, {
  name: "get_weather",
  description: "Get the weather of a city",
  schema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] },
});
const model = new FakeToolCallingModel({
  toolCalls: [[{ name: "get_weather", args: { city: "Lima" }, id: "call_1" }], []],
});
const agent = createAgent({ model, tools: [weather] });
const result = await agent.invoke({ messages: [{ role: "user", content: "Weather in Lima?" }] });
for (const message of result.messages) {
  console.log(
    message.getType(),
    JSON.stringify(message.content),
    JSON.stringify(message.tool_calls ?? []),
  );
}
