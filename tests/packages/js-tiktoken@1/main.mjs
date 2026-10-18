// From the README of js-tiktoken: encode and decode text with a bundled encoding.
import { getEncoding } from "js-tiktoken";

const encoding = getEncoding("cl100k_base");
const tokens = encoding.encode("hello world, from Buoy");
console.log(tokens.join(" "), tokens.length);
console.log(encoding.decode(tokens));
