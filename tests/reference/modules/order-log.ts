export const events: string[] = [];
export function log(name: string): void {
  events.push(name);
}
