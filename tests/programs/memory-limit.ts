function main(): void {
  const chunks: string[] = [];
  for (;;) chunks.push("x".repeat(1024 * 1024));
}

main();
