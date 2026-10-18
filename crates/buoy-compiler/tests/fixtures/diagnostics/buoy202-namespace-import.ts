import * as registry from "./modules/registry.ts";

export function register(name: string): number {
  registry.names.push(name);
  return registry.count();
}
