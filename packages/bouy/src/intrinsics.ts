import type { ActorClass } from "./runtime/Blueprint.ts";
import { fairScheduler } from "./runtime/FairScheduler.ts";
import { locate as locateClass } from "./runtime/Messaging.ts";
import { currentTurn } from "./runtime/Turn.ts";

export const tick = (): boolean => fairScheduler.spendReduction() && currentTurn() !== undefined;

export const pause = (): Promise<void> => fairScheduler.yieldToEventLoop();

export const locate = (actorClass: ActorClass, module: string, exportName: string): void =>
  locateClass(actorClass, { module, exportName });
