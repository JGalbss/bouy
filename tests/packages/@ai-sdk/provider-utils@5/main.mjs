// The helpers of @ai-sdk/provider-utils that providers use for requests and responses.
import {
  combineHeaders,
  convertBase64ToUint8Array,
  convertUint8ArrayToBase64,
  jsonSchema,
  loadApiKey,
  safeParseJSON,
  withoutTrailingSlash,
} from "@ai-sdk/provider-utils";

console.log(withoutTrailingSlash("http://127.0.0.1:9/v1/"));
console.log(JSON.stringify(combineHeaders({ a: "1" }, { b: "2", a: undefined })));
const bytes = convertBase64ToUint8Array("SGVsbG8=");
console.log(Array.from(bytes).join(","), convertUint8ArrayToBase64(bytes));
console.log(JSON.stringify(await safeParseJSON({ text: '{"a":1}' })));
const failed = await safeParseJSON({ text: "{" });
console.log(failed.success, failed.error.name);
console.log(JSON.stringify(jsonSchema({ type: "object" }).jsonSchema));
try {
  loadApiKey({
    apiKey: undefined,
    environmentVariableName: "BUOY_TEST_MISSING_KEY",
    description: "Test",
  });
} catch (error) {
  console.log(error.name);
}
