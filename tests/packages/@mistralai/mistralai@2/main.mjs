// From the README of @mistralai/mistralai: a client with its own settings and its resources.
import { Mistral } from "@mistralai/mistralai";

const client = new Mistral({ apiKey: "test-key", serverURL: "http://127.0.0.1:9" });
console.log(
  typeof client.chat.complete,
  typeof client.chat.stream,
  typeof client.embeddings.create,
);
console.log(typeof client.models.list, typeof client.agents.complete);
