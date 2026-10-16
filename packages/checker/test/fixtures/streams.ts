import { spawn } from "bouy";

class Feed {
  async list(): Promise<AsyncIterable<string>> {
    return this.words();
  }

  direct(): AsyncIterable<string> {
    return this.words();
  }

  async *words(): AsyncGenerator<string> {
    yield "word";
  }

  pages(prefix: string): AsyncGenerator<string>;
  pages(count: number): AsyncGenerator<string>;
  async *pages(start: string | number): AsyncGenerator<string> {
    yield String(start);
  }
}

abstract class Agent {
  abstract stream(prompt: string): AsyncGenerator<string>;
}

class EchoAgent extends Agent {
  override async *stream(prompt: string): AsyncGenerator<string> {
    yield prompt;
  }
}

spawn(Feed);
spawn(EchoAgent);
