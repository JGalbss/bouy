// From the README of @standard-schema/spec: a schema written by hand to the interface, and a
// function that validates with any schema of the interface. The package ships types and an
// empty module.
import * as spec from "@standard-schema/spec";

const positive = {
  "~standard": {
    version: 1,
    vendor: "bouy-test",
    validate: (value) =>
      typeof value === "number" && value > 0
        ? { value }
        : { issues: [{ message: "not positive" }] },
  },
};
function check(schema, value) {
  const result = schema["~standard"].validate(value);
  return result.issues
    ? `issues: ${result.issues.map((issue) => issue.message).join(", ")}`
    : `value: ${result.value}`;
}
console.log(Object.keys(spec).length);
console.log(check(positive, 3));
console.log(check(positive, -3));
