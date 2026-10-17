// Bare specifiers resolved from this directory, whose node_modules holds the packages.
import * as dual from "dual-pkg";
import { feature as esmFeature } from "dual-pkg/features/esm-feature.js";
import { feature as cjsFeature } from "dual-pkg/features/cjs-feature.js";
import legacy from "legacy-pkg";
import { extra } from "legacy-pkg/extra.js";
import { typed } from "typed-pkg";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

export async function report() {
  console.log("import condition", dual.format, dual.helper, dual.name);
  console.log("require condition", require("dual-pkg").format, require("dual-pkg").helper);
  console.log("patterns", esmFeature, "|", cjsFeature);
  for (const specifier of ["dual-pkg/features/internal/hidden.js", "dual-pkg/missing"]) {
    try {
      require(specifier);
    } catch (error) {
      console.log("not exported", error.code);
    }
  }
  console.log("legacy main", legacy.entry, "|", extra);
  console.log("require probes", require("legacy-pkg/extra").extra === extra);
  try {
    await import("legacy-pkg/extra");
  } catch (error) {
    console.log("import does not probe", error.code);
  }
  console.log("type module", typed);
}
