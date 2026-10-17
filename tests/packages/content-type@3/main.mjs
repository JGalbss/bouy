// From the README of content-type 3: parse and format a media type with parameters.
import { format, parse } from "content-type";

const parsed = parse("text/HTML; charset=UTF-8; q=0.5");
console.log(parsed.type, JSON.stringify(parsed.parameters));
console.log(format({ type: "application/json", parameters: { charset: "utf-8" } }));
try {
  parse("not a type");
} catch (error) {
  console.log(error.name, error.message);
}
