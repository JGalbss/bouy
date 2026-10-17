let calls = 0;
module.exports = {
  helper() {
    calls += 1;
    return "helped " + calls;
  },
};
