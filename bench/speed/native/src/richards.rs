//! Richards with the objects of `bench/speed/kernels/richards.ts` in arenas: a block, a
//! packet, or a task is an index, and `None` is null. This is the layout that escape
//! analysis and known shapes allow: no object outlives `run`.

const COUNT: u32 = 1000;
const EXPECTED_QUEUE_COUNT: i64 = 2322;
const EXPECTED_HOLD_COUNT: i64 = 928;

const ID_IDLE: usize = 0;
const ID_WORKER: usize = 1;
const ID_HANDLER_A: usize = 2;
const ID_HANDLER_B: usize = 3;
const ID_DEVICE_A: usize = 4;
const ID_DEVICE_B: usize = 5;

const KIND_DEVICE: u8 = 0;
const KIND_WORK: u8 = 1;
const DATA_SIZE: usize = 4;

const STATE_RUNNING: u32 = 0;
const STATE_RUNNABLE: u32 = 1;
const STATE_SUSPENDED: u32 = 2;
const STATE_HELD: u32 = 4;
const STATE_SUSPENDED_RUNNABLE: u32 = STATE_SUSPENDED | STATE_RUNNABLE;

struct Packet {
    link: Option<usize>,
    id: usize,
    kind: u8,
    a1: usize,
    a2: [usize; DATA_SIZE],
}

enum Task {
    Idle {
        v1: u32,
        count: u32,
    },
    Device {
        v1: Option<usize>,
    },
    Worker {
        v1: usize,
        v2: usize,
    },
    Handler {
        v1: Option<usize>,
        v2: Option<usize>,
    },
}

struct Tcb {
    link: Option<usize>,
    id: usize,
    priority: u32,
    queue: Option<usize>,
    task: Task,
    state: u32,
}

struct Scheduler {
    queue_count: i64,
    hold_count: i64,
    blocks: [Option<usize>; 6],
    list: Option<usize>,
    current: Option<usize>,
    current_id: usize,
    tcbs: Vec<Tcb>,
    packets: Vec<Packet>,
}

impl Scheduler {
    fn packet(&mut self, link: Option<usize>, id: usize, kind: u8) -> Option<usize> {
        self.packets.push(Packet {
            link,
            id,
            kind,
            a1: 0,
            a2: [0; DATA_SIZE],
        });
        Some(self.packets.len() - 1)
    }

    fn add_task(&mut self, id: usize, priority: u32, queue: Option<usize>, task: Task) {
        let state = if queue.is_none() {
            STATE_SUSPENDED
        } else {
            STATE_SUSPENDED_RUNNABLE
        };
        self.tcbs.push(Tcb {
            link: self.list,
            id,
            priority,
            queue,
            task,
            state,
        });
        let tcb = self.tcbs.len() - 1;
        self.current = Some(tcb);
        self.list = Some(tcb);
        self.blocks[id] = Some(tcb);
    }

    fn current(&self) -> usize {
        self.current.unwrap_or_default()
    }

    fn schedule(&mut self) {
        self.current = self.list;
        while let Some(tcb) = self.current {
            let state = self.tcbs[tcb].state;
            if (state & STATE_HELD) != 0 || state == STATE_SUSPENDED {
                self.current = self.tcbs[tcb].link;
            } else {
                self.current_id = self.tcbs[tcb].id;
                self.current = self.run_tcb(tcb);
            }
        }
    }

    fn run_tcb(&mut self, tcb: usize) -> Option<usize> {
        let mut packet = None;
        if self.tcbs[tcb].state == STATE_SUSPENDED_RUNNABLE
            && let Some(first) = self.tcbs[tcb].queue
        {
            let next = self.packets[first].link;
            self.tcbs[tcb].queue = next;
            self.tcbs[tcb].state = if next.is_none() {
                STATE_RUNNING
            } else {
                STATE_RUNNABLE
            };
            packet = Some(first);
        }
        match self.tcbs[tcb].task {
            Task::Idle { v1, count } => self.run_idle(tcb, v1, count),
            Task::Device { v1 } => self.run_device(tcb, v1, packet),
            Task::Worker { v1, v2 } => self.run_worker(tcb, v1, v2, packet),
            Task::Handler { v1, v2 } => self.run_handler(tcb, v1, v2, packet),
        }
    }

    fn release(&mut self, id: usize) -> Option<usize> {
        let tcb = self.blocks[id]?;
        self.tcbs[tcb].state &= !STATE_HELD;
        if self.tcbs[tcb].priority > self.tcbs[self.current()].priority {
            return Some(tcb);
        }
        self.current
    }

    fn hold_current(&mut self) -> Option<usize> {
        self.hold_count += 1;
        let current = self.current();
        self.tcbs[current].state |= STATE_HELD;
        self.tcbs[current].link
    }

    fn suspend_current(&mut self) -> Option<usize> {
        let current = self.current();
        self.tcbs[current].state |= STATE_SUSPENDED;
        Some(current)
    }

    fn queue(&mut self, packet: usize) -> Option<usize> {
        let target = self.blocks[self.packets[packet].id]?;
        self.queue_count += 1;
        self.packets[packet].link = None;
        self.packets[packet].id = self.current_id;
        let task = self.current();
        Some(self.check_priority_add(target, task, packet))
    }

    fn check_priority_add(&mut self, tcb: usize, task: usize, packet: usize) -> usize {
        match self.tcbs[tcb].queue {
            None => {
                self.tcbs[tcb].queue = Some(packet);
                self.tcbs[tcb].state |= STATE_RUNNABLE;
                if self.tcbs[tcb].priority > self.tcbs[task].priority {
                    return tcb;
                }
            }
            Some(queue) => self.tcbs[tcb].queue = Some(self.add_to(packet, Some(queue))),
        }
        task
    }

    fn add_to(&mut self, packet: usize, queue: Option<usize>) -> usize {
        self.packets[packet].link = None;
        let Some(head) = queue else { return packet };
        let mut next = head;
        while let Some(peek) = self.packets[next].link {
            next = peek;
        }
        self.packets[next].link = Some(packet);
        head
    }

    fn run_idle(&mut self, tcb: usize, v1: u32, count: u32) -> Option<usize> {
        let count = count - 1;
        if count == 0 {
            self.tcbs[tcb].task = Task::Idle { v1, count };
            return self.hold_current();
        }
        if v1 & 1 == 0 {
            self.tcbs[tcb].task = Task::Idle { v1: v1 >> 1, count };
            return self.release(ID_DEVICE_A);
        }
        self.tcbs[tcb].task = Task::Idle {
            v1: (v1 >> 1) ^ 0xd008,
            count,
        };
        self.release(ID_DEVICE_B)
    }

    fn run_device(
        &mut self,
        tcb: usize,
        v1: Option<usize>,
        packet: Option<usize>,
    ) -> Option<usize> {
        let Some(packet) = packet else {
            let Some(pending) = v1 else {
                return self.suspend_current();
            };
            self.tcbs[tcb].task = Task::Device { v1: None };
            return self.queue(pending);
        };
        self.tcbs[tcb].task = Task::Device { v1: Some(packet) };
        self.hold_current()
    }

    fn run_worker(
        &mut self,
        tcb: usize,
        v1: usize,
        v2: usize,
        packet: Option<usize>,
    ) -> Option<usize> {
        let Some(packet) = packet else {
            return self.suspend_current();
        };
        let handler = if v1 == ID_HANDLER_A {
            ID_HANDLER_B
        } else {
            ID_HANDLER_A
        };
        let mut v2 = v2;
        let target = &mut self.packets[packet];
        target.id = handler;
        target.a1 = 0;
        for slot in &mut target.a2 {
            v2 += 1;
            if v2 > 26 {
                v2 = 1;
            }
            *slot = v2;
        }
        self.tcbs[tcb].task = Task::Worker { v1: handler, v2 };
        self.queue(packet)
    }

    fn run_handler(
        &mut self,
        tcb: usize,
        v1: Option<usize>,
        v2: Option<usize>,
        packet: Option<usize>,
    ) -> Option<usize> {
        let (mut work, mut device) = (v1, v2);
        if let Some(packet) = packet {
            if self.packets[packet].kind == KIND_WORK {
                work = Some(self.add_to(packet, work));
            } else {
                device = Some(self.add_to(packet, device));
            }
        }
        if let Some(w) = work {
            let count = self.packets[w].a1;
            if count < DATA_SIZE {
                if let Some(d) = device {
                    self.tcbs[tcb].task = Task::Handler {
                        v1: work,
                        v2: self.packets[d].link,
                    };
                    self.packets[d].a1 = self.packets[w].a2[count];
                    self.packets[w].a1 = count + 1;
                    return self.queue(d);
                }
            } else {
                self.tcbs[tcb].task = Task::Handler {
                    v1: self.packets[w].link,
                    v2: device,
                };
                return self.queue(w);
            }
        }
        self.tcbs[tcb].task = Task::Handler {
            v1: work,
            v2: device,
        };
        self.suspend_current()
    }
}

/// One run of the benchmark: the queue count plus the hold count, 3250.
pub fn run() -> i64 {
    let mut s = Scheduler {
        queue_count: 0,
        hold_count: 0,
        blocks: [None; 6],
        list: None,
        current: None,
        current_id: 0,
        tcbs: Vec::with_capacity(6),
        packets: Vec::with_capacity(8),
    };
    s.add_task(
        ID_IDLE,
        0,
        None,
        Task::Idle {
            v1: 1,
            count: COUNT,
        },
    );
    let idle = s.current();
    s.tcbs[idle].state = STATE_RUNNING;

    let mut queue = s.packet(None, ID_WORKER, KIND_WORK);
    queue = s.packet(queue, ID_WORKER, KIND_WORK);
    s.add_task(
        ID_WORKER,
        1000,
        queue,
        Task::Worker {
            v1: ID_HANDLER_A,
            v2: 0,
        },
    );

    queue = s.packet(None, ID_DEVICE_A, KIND_DEVICE);
    queue = s.packet(queue, ID_DEVICE_A, KIND_DEVICE);
    queue = s.packet(queue, ID_DEVICE_A, KIND_DEVICE);
    s.add_task(
        ID_HANDLER_A,
        2000,
        queue,
        Task::Handler { v1: None, v2: None },
    );

    queue = s.packet(None, ID_DEVICE_B, KIND_DEVICE);
    queue = s.packet(queue, ID_DEVICE_B, KIND_DEVICE);
    queue = s.packet(queue, ID_DEVICE_B, KIND_DEVICE);
    s.add_task(
        ID_HANDLER_B,
        3000,
        queue,
        Task::Handler { v1: None, v2: None },
    );

    s.add_task(ID_DEVICE_A, 4000, None, Task::Device { v1: None });
    s.add_task(ID_DEVICE_B, 5000, None, Task::Device { v1: None });

    s.schedule();
    assert!(
        s.queue_count == EXPECTED_QUEUE_COUNT && s.hold_count == EXPECTED_HOLD_COUNT,
        "richards: {} queued, {} held",
        s.queue_count,
        s.hold_count
    );
    s.queue_count + s.hold_count
}
