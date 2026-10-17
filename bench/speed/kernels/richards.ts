// Richards: Martin Richards' simulation of an operating system kernel, ported from the
// Octane suite (v8/benchmarks richards.js) to TypeScript classes. One iteration runs the
// scheduler `size` times. Usage: richards.ts [warmup] [runs] [size]

const COUNT = 1000;
const EXPECTED_QUEUE_COUNT = 2322;
const EXPECTED_HOLD_COUNT = 928;

const ID_IDLE = 0;
const ID_WORKER = 1;
const ID_HANDLER_A = 2;
const ID_HANDLER_B = 3;
const ID_DEVICE_A = 4;
const ID_DEVICE_B = 5;
const NUMBER_OF_IDS = 6;

const KIND_DEVICE = 0;
const KIND_WORK = 1;
const DATA_SIZE = 4;

const STATE_RUNNING = 0;
const STATE_RUNNABLE = 1;
const STATE_SUSPENDED = 2;
const STATE_HELD = 4;
const STATE_SUSPENDED_RUNNABLE = STATE_SUSPENDED | STATE_RUNNABLE;
const STATE_NOT_HELD = ~STATE_HELD;

class Packet {
  link: Packet | null;
  id: number;
  kind: number;
  a1 = 0;
  a2: number[] = [0, 0, 0, 0];

  constructor(link: Packet | null, id: number, kind: number) {
    this.link = link;
    this.id = id;
    this.kind = kind;
  }

  addTo(queue: Packet | null): Packet {
    this.link = null;
    if (queue === null) return this;
    let next = queue;
    let peek = next.link;
    while (peek !== null) {
      next = peek;
      peek = next.link;
    }
    next.link = this;
    return queue;
  }
}

interface Task {
  run(packet: Packet | null): TaskControlBlock | null;
}

class TaskControlBlock {
  link: TaskControlBlock | null;
  id: number;
  priority: number;
  queue: Packet | null;
  task: Task;
  state: number;

  constructor(
    link: TaskControlBlock | null,
    id: number,
    priority: number,
    queue: Packet | null,
    task: Task,
  ) {
    this.link = link;
    this.id = id;
    this.priority = priority;
    this.queue = queue;
    this.task = task;
    this.state = queue === null ? STATE_SUSPENDED : STATE_SUSPENDED_RUNNABLE;
  }

  setRunning(): void {
    this.state = STATE_RUNNING;
  }

  markAsNotHeld(): void {
    this.state = this.state & STATE_NOT_HELD;
  }

  markAsHeld(): void {
    this.state = this.state | STATE_HELD;
  }

  isHeldOrSuspended(): boolean {
    return (this.state & STATE_HELD) !== 0 || this.state === STATE_SUSPENDED;
  }

  markAsSuspended(): void {
    this.state = this.state | STATE_SUSPENDED;
  }

  markAsRunnable(): void {
    this.state = this.state | STATE_RUNNABLE;
  }

  run(): TaskControlBlock | null {
    let packet: Packet | null = null;
    if (this.state === STATE_SUSPENDED_RUNNABLE && this.queue !== null) {
      packet = this.queue;
      this.queue = packet.link;
      this.state = this.queue === null ? STATE_RUNNING : STATE_RUNNABLE;
    }
    return this.task.run(packet);
  }

  checkPriorityAdd(task: TaskControlBlock, packet: Packet): TaskControlBlock {
    if (this.queue === null) {
      this.queue = packet;
      this.markAsRunnable();
      if (this.priority > task.priority) return this;
    } else {
      this.queue = packet.addTo(this.queue);
    }
    return task;
  }
}

class Scheduler {
  queueCount = 0;
  holdCount = 0;
  blocks: (TaskControlBlock | null)[] = new Array<TaskControlBlock | null>(NUMBER_OF_IDS).fill(
    null,
  );
  list: TaskControlBlock | null = null;
  currentTcb: TaskControlBlock | null = null;
  currentId = 0;

  addIdleTask(id: number, priority: number, queue: Packet | null, count: number): void {
    this.addTask(id, priority, queue, new IdleTask(this, 1, count));
    this.current().setRunning();
  }

  addWorkerTask(id: number, priority: number, queue: Packet | null): void {
    this.addTask(id, priority, queue, new WorkerTask(this, ID_HANDLER_A, 0));
  }

  addHandlerTask(id: number, priority: number, queue: Packet | null): void {
    this.addTask(id, priority, queue, new HandlerTask(this));
  }

  addDeviceTask(id: number, priority: number, queue: Packet | null): void {
    this.addTask(id, priority, queue, new DeviceTask(this));
  }

  addTask(id: number, priority: number, queue: Packet | null, task: Task): void {
    this.currentTcb = new TaskControlBlock(this.list, id, priority, queue, task);
    this.list = this.currentTcb;
    this.blocks[id] = this.currentTcb;
  }

  current(): TaskControlBlock {
    if (this.currentTcb === null) throw new Error("no current task");
    return this.currentTcb;
  }

  schedule(): void {
    this.currentTcb = this.list;
    while (this.currentTcb !== null) {
      if (this.currentTcb.isHeldOrSuspended()) {
        this.currentTcb = this.currentTcb.link;
      } else {
        this.currentId = this.currentTcb.id;
        this.currentTcb = this.currentTcb.run();
      }
    }
  }

  release(id: number): TaskControlBlock | null {
    const tcb = this.blocks[id];
    if (tcb === null) return tcb;
    tcb.markAsNotHeld();
    if (tcb.priority > this.current().priority) return tcb;
    return this.currentTcb;
  }

  holdCurrent(): TaskControlBlock | null {
    this.holdCount++;
    this.current().markAsHeld();
    return this.current().link;
  }

  suspendCurrent(): TaskControlBlock {
    this.current().markAsSuspended();
    return this.current();
  }

  queue(packet: Packet): TaskControlBlock | null {
    const target = this.blocks[packet.id];
    if (target === null) return target;
    this.queueCount++;
    packet.link = null;
    packet.id = this.currentId;
    return target.checkPriorityAdd(this.current(), packet);
  }
}

class IdleTask implements Task {
  private scheduler: Scheduler;
  private v1: number;
  private count: number;

  constructor(scheduler: Scheduler, v1: number, count: number) {
    this.scheduler = scheduler;
    this.v1 = v1;
    this.count = count;
  }

  run(_packet: Packet | null): TaskControlBlock | null {
    this.count--;
    if (this.count === 0) return this.scheduler.holdCurrent();
    if ((this.v1 & 1) === 0) {
      this.v1 = this.v1 >> 1;
      return this.scheduler.release(ID_DEVICE_A);
    }
    this.v1 = (this.v1 >> 1) ^ 0xd008;
    return this.scheduler.release(ID_DEVICE_B);
  }
}

class DeviceTask implements Task {
  private v1: Packet | null = null;

  private scheduler: Scheduler;

  constructor(scheduler: Scheduler) {
    this.scheduler = scheduler;
  }

  run(packet: Packet | null): TaskControlBlock | null {
    if (packet === null) {
      if (this.v1 === null) return this.scheduler.suspendCurrent();
      const pending = this.v1;
      this.v1 = null;
      return this.scheduler.queue(pending);
    }
    this.v1 = packet;
    return this.scheduler.holdCurrent();
  }
}

class WorkerTask implements Task {
  private scheduler: Scheduler;
  private v1: number;
  private v2: number;

  constructor(scheduler: Scheduler, v1: number, v2: number) {
    this.scheduler = scheduler;
    this.v1 = v1;
    this.v2 = v2;
  }

  run(packet: Packet | null): TaskControlBlock | null {
    if (packet === null) return this.scheduler.suspendCurrent();
    this.v1 = this.v1 === ID_HANDLER_A ? ID_HANDLER_B : ID_HANDLER_A;
    packet.id = this.v1;
    packet.a1 = 0;
    for (let i = 0; i < DATA_SIZE; i++) {
      this.v2++;
      if (this.v2 > 26) this.v2 = 1;
      packet.a2[i] = this.v2;
    }
    return this.scheduler.queue(packet);
  }
}

class HandlerTask implements Task {
  private v1: Packet | null = null;
  private v2: Packet | null = null;

  private scheduler: Scheduler;

  constructor(scheduler: Scheduler) {
    this.scheduler = scheduler;
  }

  run(packet: Packet | null): TaskControlBlock | null {
    if (packet !== null) {
      if (packet.kind === KIND_WORK) this.v1 = packet.addTo(this.v1);
      else this.v2 = packet.addTo(this.v2);
    }
    if (this.v1 !== null) {
      const count = this.v1.a1;
      if (count < DATA_SIZE) {
        if (this.v2 !== null) {
          const device = this.v2;
          this.v2 = this.v2.link;
          device.a1 = this.v1.a2[count];
          this.v1.a1 = count + 1;
          return this.scheduler.queue(device);
        }
      } else {
        const work = this.v1;
        this.v1 = this.v1.link;
        return this.scheduler.queue(work);
      }
    }
    return this.scheduler.suspendCurrent();
  }
}

function runRichards(): number {
  const scheduler = new Scheduler();
  scheduler.addIdleTask(ID_IDLE, 0, null, COUNT);

  let queue = new Packet(null, ID_WORKER, KIND_WORK);
  queue = new Packet(queue, ID_WORKER, KIND_WORK);
  scheduler.addWorkerTask(ID_WORKER, 1000, queue);

  queue = new Packet(null, ID_DEVICE_A, KIND_DEVICE);
  queue = new Packet(queue, ID_DEVICE_A, KIND_DEVICE);
  queue = new Packet(queue, ID_DEVICE_A, KIND_DEVICE);
  scheduler.addHandlerTask(ID_HANDLER_A, 2000, queue);

  queue = new Packet(null, ID_DEVICE_B, KIND_DEVICE);
  queue = new Packet(queue, ID_DEVICE_B, KIND_DEVICE);
  queue = new Packet(queue, ID_DEVICE_B, KIND_DEVICE);
  scheduler.addHandlerTask(ID_HANDLER_B, 3000, queue);

  scheduler.addDeviceTask(ID_DEVICE_A, 4000, null);
  scheduler.addDeviceTask(ID_DEVICE_B, 5000, null);

  scheduler.schedule();

  if (
    scheduler.queueCount !== EXPECTED_QUEUE_COUNT ||
    scheduler.holdCount !== EXPECTED_HOLD_COUNT
  ) {
    throw new Error(`richards: ${scheduler.queueCount} queued, ${scheduler.holdCount} held`);
  }
  return scheduler.queueCount + scheduler.holdCount;
}

function iteration(size: number): number {
  let check = 0;
  for (let i = 0; i < size; i++) check += runRichards();
  return check;
}

function bench(name: string, defaultSize: number, work: (size: number) => number): void {
  // The reference engine has neither `process` nor `performance` yet.
  const args = typeof process === "undefined" ? [] : process.argv.slice(2).map(Number);
  const now = typeof performance === "undefined" ? Date.now : () => performance.now();
  const warmup = args[0] ?? 3;
  const runs = args[1] ?? 5;
  const size = args[2] ?? defaultSize;
  const times: number[] = [];
  let check = 0;
  for (let i = 0; i < warmup + runs; i++) {
    const start = now();
    check = work(size);
    const elapsed = now() - start;
    if (i >= warmup) times.push(elapsed);
  }
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)] ?? 0;
  console.log(JSON.stringify({ kernel: name, size, median_ms: median, times_ms: times, check }));
}

bench("richards", 100, iteration);
