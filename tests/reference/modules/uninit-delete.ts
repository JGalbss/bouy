// [[Delete]] of a namespace key fails for an export without reading its binding, so an
// export that is not initialized yet does not throw.
import * as self from "./uninit-delete.ts";

export const deleted = Reflect.deleteProperty(self, "later");
export const later = 1;
