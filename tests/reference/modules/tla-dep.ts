export const steps: string[] = [];
steps.push("dep start");
await new Promise((resolve) => setTimeout(resolve, 5));
steps.push("dep end");
export const ready = true;
