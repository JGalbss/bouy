function dayType(day: string): string {
  switch (day) {
    case "sat":
    case "sun":
      return "weekend";
    case "wed":
      return "midweek";
    default:
      return "weekday";
  }
}

function score(letter: string): number {
  let points = 0;
  switch (letter) {
    case "a":
      points = 1;
      break;
    case "b":
      points = 3;
      break;
    case "q":
      points = 10;
      break;
  }
  return points;
}

function numeric(n: number): string {
  switch (n) {
    case 0:
      return "zero";
    case 1:
    case 2:
      return "small";
    default:
      if (n < 0) return "negative";
      return "large";
  }
}

function tally(items: string[]): string {
  let fruits = 0;
  let others = 0;
  for (const item of items) {
    switch (item) {
      case "apple":
      case "pear":
        fruits++;
        break;
      case "stop":
        return `stopped at ${fruits}/${others}`;
      case "skip":
        continue;
      default:
        others++;
    }
  }
  return `${fruits}/${others}`;
}

function byExpression(n: number): string {
  switch (true) {
    case n < 10:
      return "single";
    case n < 100:
      return "double";
    default:
      return "many";
  }
}

function main(): void {
  console.log(dayType("sun"), dayType("wed"), dayType("mon"));
  console.log(score("a"), score("q"), score("z"));
  console.log(numeric(0), numeric(2), numeric(-4), numeric(9));
  console.log(tally(["apple", "rock", "pear", "skip"]), tally(["pear", "stop", "apple"]));
  console.log(byExpression(5), byExpression(50), byExpression(500));
}

main();
