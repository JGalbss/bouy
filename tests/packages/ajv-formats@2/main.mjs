// From the README of ajv-formats: add the string formats to ajv, then validate them.
import Ajv from "ajv";
import addFormats from "ajv-formats";

const ajv = new Ajv();
addFormats(ajv);
const validate = ajv.compile({
  type: "object",
  properties: {
    email: { type: "string", format: "email" },
    day: { type: "string", format: "date" },
  },
});
console.log(validate({ email: "ada@example.com", day: "2026-10-16" }));
console.log(validate({ email: "nope", day: "2026-13-40" }), validate.errors[0].instancePath);
