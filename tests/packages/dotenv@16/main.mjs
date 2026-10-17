// From the README of dotenv: parse the text of a .env file. The program uses parse, because
// config reads a file and prints a tip.
import dotenv from "dotenv";

const parsed = dotenv.parse(`
# a comment
NAME=Ada
QUOTED="two words"
MULTI="line one
line two"
EMPTY=
SPACED = trimmed
`);
console.log(JSON.stringify(parsed));
console.log(JSON.stringify(dotenv.parse(Buffer.from("A=1\nB=2"))));
