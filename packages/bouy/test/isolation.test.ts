import { afterEach, describe, expect, it } from "vitest";
import { NotSendable, shutdown, spawn } from "../src/index.ts";

class Notebook {
  readonly #notes: Array<{ text: string }> = [];

  add(note: { text: string }): number {
    this.#notes.push(note);
    return this.#notes.length;
  }

  all(): Array<{ text: string }> {
    return this.#notes;
  }

  first(): string | undefined {
    return this.#notes[0]?.text;
  }
}

afterEach(() => shutdown());

describe("state isolation", () => {
  it("copies arguments, so a sender cannot mutate state it sent", async () => {
    const notebook = spawn(Notebook);
    const note = { text: "original" };
    await notebook.add(note);
    note.text = "mutated by the sender";
    expect(await notebook.first()).toBe("original");
  });

  it("copies results, so a caller cannot mutate state it received", async () => {
    const notebook = spawn(Notebook);
    await notebook.add({ text: "original" });
    const notes = await notebook.all();
    notes.splice(0, 1, { text: "replaced by the caller" });
    expect(await notebook.first()).toBe("original");
  });

  it("gives a ref no path to the actor's fields", () => {
    const notebook = spawn(Notebook);
    const visible = [
      ...Object.getOwnPropertyNames(notebook),
      ...Object.getOwnPropertySymbols(notebook).map(String),
    ];
    expect(visible).toEqual(["Symbol(bouy.actor)"]);
    expect("notes" in notebook).toBe(false);
    expect(Object.isFrozen(notebook)).toBe(true);
  });

  it("rejects values that cannot cross an actor boundary", async () => {
    const notebook = spawn(Notebook);
    const callback = { text: "x", run: () => 1 };
    await expect(notebook.add(callback)).rejects.toThrow("a function at [0][run] cannot cross");
    await expect(
      notebook.add(
        new (class Note {
          text = "y";
        })(),
      ),
    ).rejects.toBeInstanceOf(NotSendable);
  });
});
