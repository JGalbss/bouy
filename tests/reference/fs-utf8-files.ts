// readFileSync and writeFileSync of a utf8 string take the binding's fast path,
// readFileUtf8 and writeFileUtf8, which read the flag and the mode that follow the path.
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "fs-utf8-"));
const file = join(dir, "text.txt");
writeFileSync(file, "héllo", { encoding: "utf8", mode: 0o600 });
console.log(readFileSync(file, "utf8"));
console.log((statSync(file).mode & 0o777).toString(8));
writeFileSync(file, " wörld", { encoding: "utf8", flag: "a" });
console.log(readFileSync(file, { encoding: "utf8", flag: "r" }));
try {
  writeFileSync(file, "x", { encoding: "utf8", flag: "wx" });
} catch (e) {
  console.log((e as NodeJS.ErrnoException).code);
}
try {
  readFileSync(join(dir, "missing"), "utf8");
} catch (e) {
  console.log((e as NodeJS.ErrnoException).code, (e as NodeJS.ErrnoException).syscall);
}
rmSync(dir, { recursive: true });
