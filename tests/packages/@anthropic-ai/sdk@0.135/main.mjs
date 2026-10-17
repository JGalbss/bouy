// From the README of @anthropic-ai/sdk: a client with its own settings, its resources, and
// its errors.
import Anthropic, { APIError, NotFoundError, toFile } from "@anthropic-ai/sdk";

const client = new Anthropic({ apiKey: "sk-test", baseURL: "http://127.0.0.1:9", maxRetries: 0 });
console.log(client.baseURL, client.maxRetries);
console.log(typeof client.messages.create, typeof client.messages.stream);
const body = { type: "error", error: { type: "not_found_error", message: "no such model" } };
const error = APIError.generate(404, body, undefined, new Headers());
console.log(error instanceof NotFoundError, error.status, error.message);
const file = await toFile(Buffer.from("hello"), "hello.txt", { type: "text/plain" });
console.log(file.name, file.type, file.size);
