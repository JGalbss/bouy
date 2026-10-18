for (const name of ["no-main", "extensionless-main", "json-main"]) {
  try {
    const loaded = await import(`@buoytest/${name}`);
    console.log(`${name}: ${loaded.default.from}`);
  } catch (error) {
    console.log(`${name} throws ${error.code}`);
  }
}
