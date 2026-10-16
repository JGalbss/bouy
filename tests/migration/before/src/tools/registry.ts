import { jsonSchema, tool, type Tool } from "ai";
import type { Logger } from "../logger.ts";

export interface Note {
  requestId: string;
  text: string;
}

/** What a tool can see while it runs: the request it serves and the shared notebook. */
export interface ToolContext {
  requestId: string;
  notes: Note[];
  logger: Logger;
}

export interface ToolDefinition<Input = any, Output = unknown> {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: (input: Input, context: ToolContext) => Promise<Output>;
}

export class ToolRegistry implements Iterable<ToolDefinition> {
  /** The registry that the built-in tools register into when the module loads. */
  static readonly shared = new ToolRegistry();

  readonly #tools = new Map<string, ToolDefinition>();
  readonly #calls = new Map<string, number>();

  register<Input, Output>(definition: ToolDefinition<Input, Output>): this {
    if (this.#tools.has(definition.name)) {
      throw new Error(`tool "${definition.name}" is already registered`);
    }
    this.#tools.set(definition.name, definition);
    return this;
  }

  has(name: string): boolean {
    return this.#tools.has(name);
  }

  get names(): string[] {
    return [...this.#tools.keys()];
  }

  get size(): number {
    return this.#tools.size;
  }

  callCount(name: string): number {
    return this.#calls.get(name) ?? 0;
  }

  /** The `tools` option of `generateText`, bound to one request. */
  forModel(names: readonly string[], context: ToolContext): Record<string, Tool> {
    const tools: Record<string, Tool> = {};
    for (const name of names) {
      const definition = this.#tools.get(name);
      if (!definition) throw new Error(`unknown tool "${name}"`);
      tools[name] = tool({
        description: definition.description,
        inputSchema: jsonSchema(definition.parameters),
        execute: async (input: unknown) => {
          this.#calls.set(name, this.callCount(name) + 1);
          context.logger.debug("tool call", { tool: name, input });
          return definition.execute(input, context);
        },
      });
    }
    return tools;
  }

  [Symbol.iterator](): Iterator<ToolDefinition> {
    return this.#tools.values();
  }
}
