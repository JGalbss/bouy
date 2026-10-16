import { spawn } from "bouy";

interface Topic {
  readonly name: string;
}

export class ResearchAgent {
  #notes: string[] = [];

  async research(topic: Topic): Promise<string> {
    for (const word of topic.name.split(" ")) this.#notes.push(word);
    let total = 0;
    while (total < 10) total += 1;
    const sync = () => {
      for (let i = 0; i < 3; i += 1) total += i;
    };
    sync();
    return this.#notes.join(",");
  }

  count(): number {
    let n = 0;
    for (const _ of this.#notes) n += 1;
    return n;
  }
}

class Hidden {}
export { Hidden as Visible };

const agent = spawn(ResearchAgent);
console.log(await agent.research({ name: "a b" }));
