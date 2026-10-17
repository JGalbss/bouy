// The Anthropic Messages API: one answer, a bad key, and a server error.
import Anthropic from "@anthropic-ai/sdk";
import { show } from "../ai/lib/show.ts";

const client = new Anthropic();

const message = await client.messages.create({
  model: "claude-fake",
  max_tokens: 100,
  system: "You are terse",
  messages: [{ role: "user", content: "Say hello." }],
});
console.log(message.id, message.model, message.stop_reason);
console.log(show(message.content));
console.log(show(message.usage));

const stranger = new Anthropic({ apiKey: "sk-wrong-key" });
try {
  await stranger.messages.create({
    model: "claude-fake",
    max_tokens: 100,
    messages: [{ role: "user", content: "Hello?" }],
  });
} catch (error) {
  const failure = error as InstanceType<typeof Anthropic.APIError>;
  console.log(
    failure instanceof Anthropic.AuthenticationError,
    failure.status,
    show(failure.error),
  );
}

try {
  await client.messages.create(
    { model: "fake-500", max_tokens: 100, messages: [{ role: "user", content: "Fail." }] },
    { maxRetries: 0 },
  );
} catch (error) {
  const failure = error as InstanceType<typeof Anthropic.APIError>;
  console.log(failure instanceof Anthropic.InternalServerError, failure.status);
}
