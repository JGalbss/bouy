// The graph of load-before-link.mjs, with the module that does not resolve behind a source
// phase import, which loads its module too.
import "./link-error.mjs";
import source missing from "./not-there.wasm";
