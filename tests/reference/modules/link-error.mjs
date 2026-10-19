// An import of a name that the module does not export: an error of linking.
import { nothing } from "./link-error.mjs";

export const value = nothing;
