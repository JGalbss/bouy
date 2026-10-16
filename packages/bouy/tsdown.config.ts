import { defineConfig } from "tsdown";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    register: "src/register.ts",
    intrinsics: "src/intrinsics.ts",
    std: "src/std.ts",
    cli: "src/cli/main.ts",
    "thread-host": "src/thread/host.ts",
  },
  format: "esm",
  platform: "node",
  target: "node24",
  dts: false,
  clean: true,
  minify: true,
  external: ["@bouy/compiler", "@bouy/checker", "typescript"],
  noExternal: [/^effect/, /^@effect\//],
});
