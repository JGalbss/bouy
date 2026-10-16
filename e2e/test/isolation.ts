import { createOpenAI } from "@ai-sdk/openai";
import type { LanguageModel } from "ai";
import { ActorFailed, NotSendable, shutdown, spawn, type Sendable } from "bouy";
import { z } from "zod";

interface Note {
  readonly text: string;
  readonly tags: ReadonlyArray<string>;
}

const Order = z.object({ id: z.string() });

class Notebook {
  readonly #notes: Array<Note> = [];

  add(note: Note): number {
    this.#notes.push(note);
    return this.#notes.length;
  }

  first(): Note | undefined {
    return this.#notes[0];
  }
}

class Inbox {
  accept(value: z.ZodObject | LanguageModel): string {
    return value.constructor.name;
  }

  parseOrder(input: Sendable): z.infer<typeof Order> {
    return Order.parse(input);
  }
}

const notebook = spawn(Notebook);
const inbox = spawn(Inbox);
const messageText = (error: Error): string => error.message;

const draft = { text: "original", tags: ["draft"] };
const added = notebook.add(draft);
draft.text = "changed by the sender";
draft.tags.push("changed by the sender");
await added;

const withRenderer = { text: "rich", tags: [], meta: { render: (): string => "<p>rich</p>" } };
const rejection = await notebook.add(withRenderer).then(
  () => undefined,
  (error: Error) => error,
);

const model = createOpenAI({ baseURL: "http://127.0.0.1:9/v1", apiKey: "test" }).chat("gpt-5");
const thrown = await inbox.parseOrder({ id: 1 }).then(
  () => undefined,
  (error: Error) => error,
);

console.log(
  JSON.stringify({
    sent: draft,
    stored: await notebook.first(),
    rejection: {
      isNotSendable: rejection instanceof NotSendable,
      name: rejection?.name,
      message: rejection?.message,
    },
    notesAfterRejection: await notebook.add({ text: "plain", tags: [] }),
    libraryObjects: {
      schema: await inbox.accept(Order).catch(messageText),
      model: await inbox.accept(model).catch(messageText),
    },
    thrownLibraryError: {
      isActorFailed: thrown instanceof ActorFailed,
      causeName: thrown?.cause instanceof Error ? thrown.cause.name : "missing",
      causeIsZodError: thrown?.cause instanceof z.ZodError,
    },
  }),
);
await shutdown();
