import { readFileSync } from "node:fs";
import * as nodeModule from "node:module";
import { dirname, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { compile } from "@bouy/compiler";
import { Schema } from "effect";

export type Host = "node" | "bun";

export class CompileFailed extends Schema.TaggedError<CompileFailed>()("CompileFailed", {
  file: Schema.String,
  diagnostics: Schema.Array(Schema.String),
}) {
  override get message(): string {
    return `Bouy could not compile ${this.file}:\n${this.diagnostics.join("\n")}`;
  }
}

const RUNTIME_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SOURCE_FILE = /\.(?:m?ts|tsx)$/u;
const RELATIVE_JS = /^\.{1,2}\/.*\.js$/u;

const isUserSource = (path: string): boolean =>
  SOURCE_FILE.test(path) &&
  !path.endsWith(".d.ts") &&
  !path.includes(`${sep}node_modules${sep}`) &&
  !path.startsWith(RUNTIME_ROOT);

export const compileSource = (path: string, source: string): string => {
  const result = compile(path, source);
  if (result.kind === "failed") {
    const diagnostics = result.diagnostics.map(
      ({ line, column, message }) => `${path}:${line}:${column} - ${message}`,
    );
    throw new CompileFailed({ file: path, diagnostics });
  }
  if (result.sourceMap === undefined) return result.code;
  const map = Buffer.from(result.sourceMap).toString("base64");
  return `${result.code}\n//# sourceMappingURL=data:application/json;base64,${map}\n`;
};

const INSTALLERS: Record<Host, () => void> = {
  node: () => {
    process.setSourceMapsEnabled(true);
    nodeModule.registerHooks({
      resolve: (specifier, context, nextResolve) => {
        try {
          return nextResolve(specifier, context);
        } catch (cause) {
          if (!RELATIVE_JS.test(specifier)) throw cause;
          return nextResolve(specifier.replace(/\.js$/u, ".ts"), context);
        }
      },
      load: (url, context, nextLoad) => {
        if (!url.startsWith("file:")) return nextLoad(url, context);
        const path = fileURLToPath(url);
        if (!isUserSource(path)) return nextLoad(url, context);
        return {
          format: "module",
          source: compileSource(path, readFileSync(path, "utf8")),
          shortCircuit: true,
        };
      },
    });
  },
  bun: () => {
    Bun.plugin({
      name: "bouy",
      setup: (build) => {
        build.onLoad({ filter: SOURCE_FILE }, ({ path }) => {
          const source = readFileSync(path, "utf8");
          if (!isUserSource(path)) return { contents: source, loader: "ts" };
          return { contents: compileSource(path, source), loader: "js" };
        });
      },
    });
  },
};

const installed = new Set<Host>();

export const currentHost = (): Host => {
  if (process.versions.bun === undefined) return "node";
  return "bun";
};

export const installLoader = (): Host => {
  const host = currentHost();
  if (installed.has(host)) return host;
  INSTALLERS[host]();
  installed.add(host);
  return host;
};

export const entryUrl = (entry: string): string => pathToFileURL(entry).href;
