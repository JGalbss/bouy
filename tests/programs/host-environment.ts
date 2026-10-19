// The program sees the environment of the CLI: the VM keeps none of the variables that its
// start sets, and PATH keeps the order that the CLI had.
const started = [
  process.env.ROOTDIR,
  process.env.BINDIR,
  process.env.EMU,
  process.env.PROGNAME,
  process.env.ERL_ROOTDIR,
];
console.log(started.filter((value) => value !== undefined).length);
console.log(process.env.PATH === process.env.EXPECTED_PATH);
