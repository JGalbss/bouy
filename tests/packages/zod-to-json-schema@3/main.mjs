// From the README of zod-to-json-schema: the JSON Schema of a zod 3 schema.
import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";

const User = z.object({
  name: z.string().describe("The full name"),
  age: z.number().int().optional(),
  role: z.enum(["admin", "user"]),
});
console.log(JSON.stringify(zodToJsonSchema(User, "User")));
console.log(JSON.stringify(zodToJsonSchema(User, { target: "openApi3" })));
