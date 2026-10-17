// From the README of execa: run commands and read their output and exit codes.
import { execa } from "execa";

const { stdout, exitCode } = await execa("echo", ["hello", "from", "execa"]);
console.log(JSON.stringify(stdout), exitCode);
const failed = await execa("sh", ["-c", "echo oops >&2; exit 3"], { reject: false });
console.log(failed.exitCode, JSON.stringify(failed.stderr), failed.failed);
const piped = await execa("echo", ["b\na"]).pipe("sort");
console.log(JSON.stringify(piped.stdout));
