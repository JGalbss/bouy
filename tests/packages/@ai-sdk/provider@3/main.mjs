// The error classes of @ai-sdk/provider, which every provider throws.
import { APICallError, TypeValidationError, getErrorMessage } from "@ai-sdk/provider";

for (const statusCode of [400, 429, 500]) {
  const error = new APICallError({
    message: `status ${statusCode}`,
    url: "http://127.0.0.1:9/v1/chat/completions",
    requestBodyValues: { model: "m" },
    statusCode,
  });
  console.log(error.name, error.message, error.isRetryable, APICallError.isInstance(error));
}
const wrapped = TypeValidationError.wrap({
  value: { a: 1 },
  cause: new Error("expected a string"),
});
console.log(wrapped.name, JSON.stringify(wrapped.value), TypeValidationError.isInstance(wrapped));
console.log(TypeValidationError.wrap({ value: 1, cause: wrapped }) === wrapped);
console.log(
  getErrorMessage(new Error("boom")),
  getErrorMessage("text"),
  getErrorMessage(undefined),
);
