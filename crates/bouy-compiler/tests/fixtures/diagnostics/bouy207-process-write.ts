export function configure(): void {
  process.env.MODE = "dev";
  process.env.PATH ||= "unset";
  process.exitCode = 3;
  process.argv.push("--verbose");
}
