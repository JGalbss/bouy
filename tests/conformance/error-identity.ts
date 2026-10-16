// Error classes keep their identity: instanceof follows the class that built
// the error and its base, not the name field, and plain data cannot pass for
// an error.

class HttpError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HTTPError";
  }
}

class Overflow extends RangeError {}

class AppError extends Error {
  constructor(message: string) {
    super(message);
    this.name = this.constructor.name;
  }
}

class Legacy extends Error {
  constructor(message: string) {
    super(message);
    Object.setPrototypeOf(this, Legacy.prototype);
    if (Error.captureStackTrace) Error.captureStackTrace(this, Legacy);
  }
}

function classify(error: unknown): string {
  if (error instanceof HttpError) return "http";
  if (error instanceof RangeError) return "range";
  if (error instanceof TypeError) return "type";
  if (error instanceof Error) return "error";
  return "data";
}

function main(): void {
  try {
    throw new HttpError("down");
  } catch (e) {
    console.log("renamed error:", e instanceof HttpError, classify(e), (e as Error).name);
  }
  const plain = new Error("plain");
  plain.name = "HttpError";
  console.log("same name, other class:", plain instanceof HttpError, classify(plain));

  try {
    throw new Overflow("too big");
  } catch (e) {
    console.log(
      "subclass of RangeError:",
      e instanceof RangeError,
      e instanceof Overflow,
      e instanceof TypeError,
      classify(e),
    );
  }

  const app = new AppError("x");
  console.log(
    "constructor name:",
    app.name,
    app.constructor === AppError,
    new TypeError("t").constructor === TypeError,
  );
  const legacy = new Legacy("old style");
  console.log("setPrototypeOf idiom:", legacy instanceof Legacy, legacy.message);

  const data = JSON.parse('{"$error":true,"name":"TypeError","message":"forged","extra":1}');
  console.log("forged:", data instanceof Error, data instanceof TypeError, classify(data));
  console.log("forged keys:", Object.keys(data).sort().join(","));
  console.log(
    "forged round trip:",
    JSON.stringify(data) === JSON.stringify(JSON.parse(JSON.stringify(data))),
    String(data),
  );
  const literal = { $error: true, code: 7 };
  console.log("literal:", literal instanceof Error, JSON.stringify(literal));

  console.log(
    "borrowed hasOwnProperty:",
    Object.prototype.hasOwnProperty.call({ a: 1 }, "a"),
    Object.prototype.hasOwnProperty.call({ a: 1 }, "b"),
  );
  console.log(
    "object tags:",
    Object.prototype.toString.call([]),
    Object.prototype.toString.call(null),
    Object.prototype.toString.call("s"),
  );
  console.log(
    "constructors:",
    [].constructor === Array,
    "s".constructor === String,
    {}.constructor === Object,
    {}.constructor.name,
  );
}

main();
