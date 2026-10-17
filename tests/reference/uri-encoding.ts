// encodeURI, decodeURI, and their Component forms over UTF-8, with the
// URIError of a lone surrogate or a malformed escape; escape and unescape;
// and the HTML methods of String.prototype from Annex B.
console.log(
  encodeURI("http://a.b/c d?x=ä&y=😀#f"),
  encodeURIComponent("a b&c=d/é"),
  decodeURI("%41%2F%e4%B8%AD%3B"),
  decodeURIComponent("%41%2F%E4%B8%AD"),
);
console.log(
  escape("aé ✓@*_+-./"),
  unescape("%41%u2713%zz%"),
  "x".anchor('a"b'),
  "y".fontsize(7),
  "z".bold(),
);
for (const f of [
  () => encodeURI("\ud800"),
  () => decodeURI("%"),
  () => decodeURI("%C0%80"),
  () => decodeURIComponent("%ED%A0%80"),
]) {
  try {
    f();
  } catch (e) {
    console.log((e as Error).name, (e as Error).message);
  }
}
