import { spawn } from "buoy";

class Client {
  #server: any;

  connect(server: any): void {
    this.#server = server;
  }

  start(): string {
    return this.#server.handshake();
  }

  hello(): string {
    return "hello";
  }
}

class Server {
  #client: any;

  connect(client: any): void {
    this.#client = client;
  }

  handshake(): string {
    // The client waits for this call, so calling it back would deadlock.
    try {
      return this.#client.hello();
    } catch (error) {
      return `${error._tag}: ${error.message}`;
    }
  }
}

async function main(): Promise<void> {
  const client = spawn(Client, { name: "client" });
  const server = spawn(Server, { name: "server" });
  await client.connect(server);
  await server.connect(client);
  console.log(await client.start());
  console.log(`the client still answers: ${await client.hello()}`);
}

await main();
