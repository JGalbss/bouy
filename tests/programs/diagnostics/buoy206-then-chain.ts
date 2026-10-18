import { spawn } from "buoy";

class Echo {
  echo(text: string): string {
    return text;
  }
}

async function main(): Promise<void> {
  const echo = spawn(Echo);
  echo.echo("hi").then((text: string) => console.log(text));
}

await main();
