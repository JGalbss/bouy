// From the documentation of langchain 0.3: split a text into chunks and keep them as
// documents in a memory store. The package has no root export, so the program imports its
// subpaths.
import { Document } from "langchain/document";
import { RecursiveCharacterTextSplitter } from "langchain/text_splitter";
import { InMemoryStore } from "@langchain/core/stores";

const splitter = new RecursiveCharacterTextSplitter({ chunkSize: 24, chunkOverlap: 0 });
const text = "Buoy runs TypeScript on BEAM. Each actor has its own heap.\n\nActors restart alone.";
const chunks = await splitter.splitText(text);
console.log(JSON.stringify(chunks));

const documents = chunks.map(
  (chunk, index) => new Document({ pageContent: chunk, metadata: { index } }),
);
const store = new InMemoryStore();
await store.mset(documents.map((document) => [`chunk-${document.metadata.index}`, document]));
const keys = [];
for await (const key of store.yieldKeys("chunk-")) keys.push(key);
console.log(keys.join(" "));
console.log((await store.mget(["chunk-1"]))[0].pageContent);
