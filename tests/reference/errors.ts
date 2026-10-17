// Custom error classes, instanceof, finally, and rethrow.
class ValidationError extends Error {
  field: string;
  constructor(field: string, message: string) {
    super(message);
    this.name = "ValidationError";
    this.field = field;
  }
}

function validate(input: { age?: number }): number {
  if (input.age === undefined) throw new ValidationError("age", "age is required");
  if (input.age < 0) throw new RangeError("age must be positive");
  return input.age;
}

const log: string[] = [];
for (const input of [{ age: 3 }, {}, { age: -1 }]) {
  try {
    log.push(`ok ${validate(input)}`);
  } catch (e) {
    if (e instanceof ValidationError) log.push(`invalid ${e.field}: ${e.message}`);
    else if (e instanceof RangeError) log.push(`range: ${e.message}`);
    else throw e;
  } finally {
    log.push("checked");
  }
}
console.log(log.join("; "));

function withFinally(): string {
  try {
    return "from try";
  } finally {
    log.push("finally ran");
  }
}
console.log(withFinally(), log[log.length - 1]);

const err = new ValidationError("x", "bad");
console.log(err instanceof Error, err.name, String(err), Object.keys(err));
try {
  null!.toString();
} catch (e) {
  console.log(e instanceof TypeError);
}
