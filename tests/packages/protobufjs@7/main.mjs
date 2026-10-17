// From the README of protobufjs: parse a .proto definition, then encode, decode, and verify
// a message.
import protobuf from "protobufjs";

const { root } = protobuf.parse(`
  syntax = "proto3";
  package demo;
  message User {
    string name = 1;
    int32 age = 2;
    repeated string tags = 3;
  }
`);
const User = root.lookupType("demo.User");
console.log(User.verify({ name: "Ada", age: "old" }));
const message = User.create({ name: "Ada", age: 36, tags: ["math"] });
const bytes = User.encode(message).finish();
console.log(Array.from(bytes).join(" "));
console.log(JSON.stringify(User.toObject(User.decode(bytes))));
