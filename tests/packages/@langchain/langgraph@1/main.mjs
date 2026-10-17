// From the README of @langchain/langgraph: a state graph of two nodes, compiled and invoked.
import { Annotation, END, START, StateGraph } from "@langchain/langgraph";

const State = Annotation.Root({
  steps: Annotation({ reducer: (left, right) => left.concat(right), default: () => [] }),
  count: Annotation(),
});
const graph = new StateGraph(State)
  .addNode("plan", (state) => ({ steps: ["plan"], count: state.count + 1 }))
  .addNode("act", (state) => ({ steps: ["act"], count: state.count * 10 }))
  .addEdge(START, "plan")
  .addConditionalEdges("plan", (state) => (state.count > 1 ? "act" : END))
  .addEdge("act", END)
  .compile();

console.log(JSON.stringify(await graph.invoke({ count: 0 })));
console.log(JSON.stringify(await graph.invoke({ count: 4 })));
