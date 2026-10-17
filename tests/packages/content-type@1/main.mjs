// From the README of content-type: parse and format a media type with parameters.
import contentType from "content-type";

const parsed = contentType.parse("text/HTML; charset=UTF-8; q=0.5");
console.log(parsed.type, JSON.stringify(parsed.parameters));
console.log(contentType.format({ type: "application/json", parameters: { charset: "utf-8" } }));
try {
  contentType.parse("not a type");
} catch (error) {
  console.log(error.name, error.message);
}
