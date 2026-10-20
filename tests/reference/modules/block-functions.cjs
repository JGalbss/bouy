// Annex B.3.3 in sloppy code: a function declared in a block is also a var of the
// enclosing function, which the declaration sets when it runs, unless a `let` of the
// same name sits between them.
function blockFunctions() {
  const seen = [];
  seen.push(typeof early);
  {
    function early() {
      return "inner";
    }
  }
  seen.push(early());
  function outer() {
    return "outer";
  }
  {
    function outer() {
      return "replaced";
    }
  }
  seen.push(outer());
  {
    let shadow = 1;
    {
      function shadow() {}
    }
    seen.push(typeof shadow);
  }
  seen.push(typeof shadow);
  if (seen.length > 0) function late() {}
  seen.push(typeof late);
  return seen.join(",");
}

module.exports = blockFunctions();
