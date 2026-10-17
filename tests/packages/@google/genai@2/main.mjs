// From the README of @google/genai: a client, and the helpers that build request content.
import { GoogleGenAI, Type, createPartFromText, createUserContent } from "@google/genai";

const ai = new GoogleGenAI({ apiKey: "test-key" });
console.log(typeof ai.models.generateContent, typeof ai.chats.create);
console.log(JSON.stringify(createUserContent(["Hello", createPartFromText("world")])));
console.log(Type.OBJECT, Type.STRING, Type.ARRAY);
