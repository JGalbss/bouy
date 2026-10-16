import { shutdown, spawn } from "bouy";
import { z } from "zod";

const Age = z.number().min(18);

class Validator {
  check(age: number): string {
    return Age.safeParse(age).error?.issues[0]?.message ?? "valid";
  }
}

class Configurer {
  replaceErrorMessages(message: string): void {
    z.config({ customError: () => message });
  }
}

const validator = spawn(Validator);
const configurer = spawn(Configurer);

const before = await validator.check(5);
await configurer.replaceErrorMessages("set by another actor");
const after = await validator.check(5);

console.log(JSON.stringify({ before, after }));
await shutdown();
