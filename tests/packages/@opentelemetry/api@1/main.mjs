// From the README of @opentelemetry/api: the API with no SDK registered, where every span is
// a no-op and context still flows.
import { ROOT_CONTEXT, context, createContextKey, trace } from "@opentelemetry/api";

const tracer = trace.getTracer("buoy-test", "1.0.0");
const span = tracer.startSpan("work");
console.log(span.isRecording(), JSON.stringify(span.spanContext()));
span.setAttribute("key", "value").end();
const key = createContextKey("request");
const scoped = ROOT_CONTEXT.setValue(key, "r-7");
console.log(context.with(scoped, () => context.active().getValue(key)));
console.log(context.active().getValue(key));
tracer.startActiveSpan("outer", (outer) => {
  console.log(trace.getActiveSpan() === outer);
  outer.end();
});
