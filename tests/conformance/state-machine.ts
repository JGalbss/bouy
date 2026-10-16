type State = "idle" | "selecting" | "paying" | "dispensing";

interface Machine {
  state: State;
  credit: number;
  item: string;
  log: string[];
}

function step(machine: Machine, event: string, amount = 0): Machine {
  const log = [...machine.log];
  switch (machine.state) {
    case "idle":
      if (event === "coin") {
        log.push(`credit ${amount}`);
        return { ...machine, state: "selecting", credit: amount, log };
      }
      log.push(`ignored ${event} while idle`);
      return { ...machine, log };
    case "selecting":
      if (event === "coin") {
        return {
          ...machine,
          credit: machine.credit + amount,
          log: [...log, `credit ${machine.credit + amount}`],
        };
      }
      if (event === "pick") {
        return { ...machine, state: "paying", item: "soda", log: [...log, "picked soda"] };
      }
      if (event === "cancel") {
        return { state: "idle", credit: 0, item: "", log: [...log, `refund ${machine.credit}`] };
      }
      break;
    case "paying":
      if (machine.credit >= 3) {
        return {
          ...machine,
          state: "dispensing",
          credit: machine.credit - 3,
          log: [...log, "paid"],
        };
      }
      return { ...machine, state: "selecting", log: [...log, "not enough credit"] };
    case "dispensing":
      return {
        state: "idle",
        credit: 0,
        item: "",
        log: [...log, `dispensed ${machine.item}, change ${machine.credit}`],
      };
  }
  return { ...machine, log: [...log, `unexpected ${event} in ${machine.state}`] };
}

function main(): void {
  let machine: Machine = { state: "idle", credit: 0, item: "", log: [] };
  const events: [string, number][] = [
    ["pick", 0],
    ["coin", 1],
    ["pick", 0],
    ["check", 0],
    ["coin", 5],
    ["pick", 0],
    ["check", 0],
    ["done", 0],
    ["coin", 2],
    ["dance", 0],
    ["cancel", 0],
  ];
  for (const [event, amount] of events) {
    machine = step(machine, event, amount);
  }
  console.log(machine.log.join("\n"));
  console.log(machine.state, machine.credit);
}

main();
