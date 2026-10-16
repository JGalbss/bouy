// Default exports and imports, named and star re-exports, and a namespace re-export.
import double, { TEN } from "./util.ts";
import { twice, ten, Missing, utilities } from "./index.ts";
import * as all from "./index.ts";

console.log(double(TEN), twice(ten), new Missing("m") instanceof Missing);
console.log(all.TEN, all.twice(4), utilities.TEN, utilities.default(3));
