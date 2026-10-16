import { shutdown, spawn, type Sendable } from "bouy";
import { z } from "zod";

const Signup = z.object({
  email: z.email(),
  age: z.number().int().min(13),
  plan: z.enum(["free", "team"]),
});

type Signup = z.infer<typeof Signup>;

interface Issue {
  readonly path: string;
  readonly message: string;
}

interface Tally {
  readonly accepted: number;
  readonly rejected: number;
}

type Validation =
  | { readonly kind: "accepted"; readonly signup: Signup }
  | { readonly kind: "rejected"; readonly issues: ReadonlyArray<Issue> };

class SignupValidator {
  #accepted = 0;
  #rejected = 0;

  validate(record: Sendable): Validation {
    const result = Signup.safeParse(record);
    if (result.success) {
      this.#accepted += 1;
      return { kind: "accepted", signup: result.data };
    }
    this.#rejected += 1;
    const issues = result.error.issues.map((issue) => ({
      path: issue.path.map(String).join("."),
      message: issue.message,
    }));
    return { kind: "rejected", issues };
  }

  tally(): Tally {
    return { accepted: this.#accepted, rejected: this.#rejected };
  }
}

const validator = spawn(SignupValidator);

const records = [
  { email: "ada@example.com", age: 36, plan: "team" },
  { email: "grace-at-example.com", age: 12, plan: "enterprise" },
  { email: "linus@example.com", age: 21 },
];

const validations = await Promise.all(records.map((record) => validator.validate(record)));
for (const validation of validations) console.log(JSON.stringify(validation));
console.log(JSON.stringify(await validator.tally()));

await shutdown();
