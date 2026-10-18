// A module whose graph fails twice: an import that names no export, then a request that
// does not resolve. Loading the graph meets the missing module before linking runs.
import "./link-error.mjs";
import "./not-there.mjs";
