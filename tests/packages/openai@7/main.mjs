// From the README of openai: a client with its own settings, its resources, and its errors.
import OpenAI, { APIError, NotFoundError, toFile } from "openai";

const client = new OpenAI({ apiKey: "sk-test", baseURL: "http://127.0.0.1:9/v1", maxRetries: 0 });
console.log(client.baseURL, client.maxRetries);
console.log(typeof client.chat.completions.create, typeof client.responses.create);
const error = APIError.generate(
  404,
  { error: { message: "no such model" } },
  undefined,
  new Headers(),
);
console.log(error instanceof NotFoundError, error.status, error.message);
const file = await toFile(Buffer.from("hello"), "hello.txt", { type: "text/plain" });
console.log(file.name, file.type, file.size);
