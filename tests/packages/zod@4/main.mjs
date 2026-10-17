// From the README of zod: a schema, a parse, the issues of a failed parse, a transform, and
// the JSON Schema of the schema.
import { z } from "zod";

const User = z.object({
  name: z.string().min(1),
  age: z.number().int().nonnegative(),
  email: z.email().optional(),
  tags: z.array(z.string()).default([]),
});
console.log(JSON.stringify(User.parse({ name: "Ada", age: 36 })));
const failed = User.safeParse({ name: "", age: -1, email: "nope" });
console.log(
  failed.success,
  JSON.stringify(failed.error.issues.map((issue) => [issue.path, issue.code])),
);
const Celsius = z
  .string()
  .transform((text) => Number.parseFloat(text))
  .pipe(z.number());
console.log(Celsius.parse("21.5"));
console.log(JSON.stringify(z.toJSONSchema(User)));
