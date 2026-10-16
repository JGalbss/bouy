import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

const CONVENTIONAL_SUBJECT =
  /^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([\w./-]+\))?!?: \S.*$/u;
const MAX_SUBJECT_LENGTH = 100;

const { values } = parseArgs({
  options: { range: { type: "string" }, "message-file": { type: "string" } },
});

if (values.range === undefined && values["message-file"] === undefined) {
  console.error("Pass --range <from..to> or --message-file <path>.");
  process.exit(2);
}

const subjects =
  values.range === undefined
    ? [readFileSync(values["message-file"] ?? "", "utf8").split("\n")[0] ?? ""]
    : execFileSync("git", ["log", "--no-merges", "--format=%s", values.range], {
        encoding: "utf8",
      })
        .split("\n")
        .filter((subject) => subject.length > 0);

const rejected = subjects.filter(
  (subject) => !CONVENTIONAL_SUBJECT.test(subject) || subject.length > MAX_SUBJECT_LENGTH,
);

for (const subject of rejected) {
  console.error(`Not a Conventional Commit subject: "${subject}"`);
}

if (rejected.length > 0) {
  console.error('Write "<type>(<scope>): <summary>", for example "feat(runtime): add mailboxes".');
  process.exit(1);
}
