import { pathToFileURL } from "node:url";

console.log(
  JSON.stringify({
    argv: process.argv.slice(1),
    isMain: import.meta.url === pathToFileURL(process.argv[1] ?? "").href,
    importMetaMain: import.meta.main,
  }),
);
