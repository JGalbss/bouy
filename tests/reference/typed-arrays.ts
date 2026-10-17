// Typed arrays, ArrayBuffer, and DataView: element conversions, the
// integer-indexed properties, views over one buffer, resizable buffers,
// transfer, and the typed array methods.
const bytes = new Uint8Array([1, 2, 300, -1]);
console.log(
  bytes,
  bytes.length,
  bytes[2],
  bytes[3],
  bytes[9],
  Object.keys(bytes),
  "2" in bytes,
  "9" in bytes,
);
const floats = new Float64Array(3);
floats[0] = 1.5;
floats[1] = NaN;
floats[5] = 7;
console.log(
  floats,
  floats[5],
  Array.from(floats),
  new Float32Array([1.1])[0],
  new Float16Array([1.337])[0],
);
const buffer = new ArrayBuffer(8);
const view = new DataView(buffer);
view.setFloat32(0, 1.5);
view.setInt16(4, -2, true);
console.log(
  view.getFloat32(0),
  view.getInt16(4, true),
  view.getUint8(4),
  new Uint8Array(buffer),
  buffer,
);
const ints = new Int32Array(buffer, 4, 1);
console.log(
  ints[0],
  ints.byteOffset,
  ints.buffer === buffer,
  new BigInt64Array([1n, -2n]),
  new BigUint64Array(new BigInt64Array([-2n]).buffer)[0],
);
console.log(
  new Int16Array([3, -1, 2]).sort(),
  Uint8ClampedArray.of(300, -5, 1.5, 2.5),
  new Float64Array([0, -0, NaN, -Infinity]).sort(),
);
const resizable = new ArrayBuffer(4, { maxByteLength: 8 });
const tracking = new Uint8Array(resizable);
resizable.resize(8);
console.log(tracking.length, resizable.resizable, resizable.byteLength, resizable.maxByteLength);
const moved = buffer.transfer();
console.log(buffer.detached, buffer.byteLength, moved.byteLength, ints.length, ints[0]);
const sample = new Int8Array([5, 1, 4, 2, 3]);
console.log(
  sample.map((x) => x * 2),
  sample.filter((x) => x > 2),
  sample.slice(1, 3),
  sample.subarray(2),
  sample.toSorted(),
  sample.with(0, 9),
);
console.log(
  sample.indexOf(4),
  sample.includes(9),
  sample.join("-"),
  sample.reduce((a, b) => a + b),
  [...sample.entries()].length,
  Object.prototype.toString.call(sample),
);
try {
  new Uint8Array(new ArrayBuffer(3), 1, 4);
} catch (error) {
  console.log((error as Error).name);
}
