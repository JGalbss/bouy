// From the README of @langchain/core: a prompt, a chat model, and an output parser joined
// into one runnable chain, with the fake chat model of @langchain/core/utils/testing.
import { StringOutputParser } from "@langchain/core/output_parsers";
import { ChatPromptTemplate } from "@langchain/core/prompts";
import { RunnableLambda } from "@langchain/core/runnables";
import { FakeListChatModel } from "@langchain/core/utils/testing";

const prompt = ChatPromptTemplate.fromMessages([
  ["system", "You are a {role}."],
  ["human", "Tell me about {topic}."],
]);
const formatted = await prompt.formatMessages({ role: "guide", topic: "Lima" });
console.log(formatted.map((message) => `${message.getType()}: ${message.content}`).join(" | "));

const model = new FakeListChatModel({ responses: ["Lima is the capital of Peru.", "Second."] });
const chain = prompt.pipe(model).pipe(new StringOutputParser());
console.log(await chain.invoke({ role: "guide", topic: "Lima" }));
console.log(await chain.invoke({ role: "guide", topic: "Cusco" }));

const shout = RunnableLambda.from((text) => text.toUpperCase());
console.log(JSON.stringify(await shout.batch(["a", "b"])));
