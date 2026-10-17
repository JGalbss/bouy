// The schemas of main.mjs with the eval-free configuration of zod (testing.md section 5.8,
// code generation): a failure here and not in main.mjs is a gap in dynamic code.
import { z } from "zod";

z.config({ jitless: true });
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
