// structuredClone of typed arrays over one buffer, a DataView, primitive
// wrappers, and a BigInt: views keep sharing their copied buffer.
const buf = new ArrayBuffer(4);
const u8 = new Uint8Array(buf);
u8[0] = 7;
const copy = structuredClone({
  u8,
  view: new Uint16Array(buf, 2, 1),
  n: Object(5),
  s: new String("hi"),
  big: 10n,
  d: new DataView(buf, 1),
});
copy.u8[1] = 9;
console.log(
  copy.u8,
  copy.view.buffer === copy.u8.buffer,
  u8[1],
  copy.n,
  copy.s,
  copy.big,
  copy.d.byteOffset,
);
