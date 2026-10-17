// From the README of eventsource-parser: feed a stream in arbitrary chunks and get each
// event once it is complete.
import { createParser } from "eventsource-parser";

const parser = createParser({
  onEvent: (event) => console.log(JSON.stringify([event.event, event.id, event.data])),
  onRetry: (interval) => console.log("retry", interval),
});
for (const chunk of [
  "data: hel",
  "lo\n\nevent: up",
  "date\nid: 7\ndata: a\ndata: b\n\nretry: 3000\n\n",
  ": comment\n\n",
]) {
  parser.feed(chunk);
}
parser.reset();
