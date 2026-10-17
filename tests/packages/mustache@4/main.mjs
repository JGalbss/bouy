// From the README of mustache: render a template with variables, a section, and escaping.
import Mustache from "mustache";

const view = { name: "Ada", items: [{ item: "a" }, { item: "b" }], html: "<b>bold</b>", empty: [] };
console.log(Mustache.render("Hello {{name}}! {{#items}}[{{item}}]{{/items}}", view));
console.log(Mustache.render("{{html}} {{{html}}} {{^empty}}none{{/empty}}", view));
console.log(JSON.stringify(Mustache.parse("a {{b}} c")));
