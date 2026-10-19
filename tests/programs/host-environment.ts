// The program sees the environment of the CLI: the VM keeps none of the variables that its
// start and the CLI set, and PATH keeps the order that the CLI had.
const started = [
  process.env.ROOTDIR,
  process.env.BINDIR,
  process.env.EMU,
  process.env.PROGNAME,
  process.env.ERL_ROOTDIR,
  process.env.ERL_CRASH_DUMP_SECONDS,
  process.env.BUOY_COMPILER,
];
console.log(started.filter((value) => value !== undefined).length);
console.log(process.env.PATH === process.env.EXPECTED_PATH);
