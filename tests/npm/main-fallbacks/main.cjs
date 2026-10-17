for (const name of ["no-main", "extensionless-main", "json-main"]) {
  console.log(`${name}: ${require(`@bouytest/${name}`).from}`);
}
