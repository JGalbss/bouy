for (const name of ["no-main", "extensionless-main", "json-main"]) {
  console.log(`${name}: ${require(`@buoytest/${name}`).from}`);
}
