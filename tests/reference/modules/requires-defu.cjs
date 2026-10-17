// The `require` condition of defu's `exports` selects its CommonJS build.
const { defu } = require("defu");
module.exports = { merged: defu({ a: 1 }, { a: 2, b: 2 }), defu };
