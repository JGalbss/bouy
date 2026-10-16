class ValidationError extends Error {
  field: string;
  constructor(field: string, message: string) {
    super(message);
    this.name = "ValidationError";
    this.field = field;
  }
}

class NotFound extends Error {
  constructor(what: string) {
    super(`${what} not found`);
    this.name = "NotFound";
  }
}

function validate(input: { age?: number }): number {
  if (input.age === undefined) throw new ValidationError("age", "age is required");
  if (input.age < 0) throw new ValidationError("age", "age must be positive");
  return input.age;
}

function lookup(id: number): string {
  if (id !== 1) throw new NotFound(`user ${id}`);
  return "ann";
}

function attempt(fn: () => unknown): string {
  try {
    return `ok: ${fn()}`;
  } catch (e) {
    if (e instanceof ValidationError) {
      return `invalid ${e.field}: ${e.message}`;
    }
    if (e instanceof NotFound) {
      return `${e.name}: ${e.message}`;
    }
    return "unknown";
  }
}

function main(): void {
  console.log(attempt(() => validate({ age: 3 })));
  console.log(attempt(() => validate({})));
  console.log(attempt(() => validate({ age: -1 })));
  console.log(attempt(() => lookup(1)));
  console.log(attempt(() => lookup(7)));
  const error = new ValidationError("name", "bad name");
  console.log(error instanceof Error, error instanceof ValidationError, error instanceof NotFound);
  console.log(error.name, error.message, error.field);
  const plain = new Error("plain");
  console.log(plain.name, plain.message, plain instanceof ValidationError);
}

main();
