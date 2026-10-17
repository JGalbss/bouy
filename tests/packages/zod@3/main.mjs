// From the README of zod 3: a schema, a parse, the issues of a failed parse, and a transform.
import { z } from "zod";

const User = z.object({
  name: z.string().min(1),
  age: z.number().int().nonnegative(),
  email: z.string().email().optional(),
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
console.log(User.shape.age.isInt, User.shape.age.minValue);
