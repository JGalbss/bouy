function main(): void {
  console.log(1 === 1, 1 === 1.0, "1" === "1", 1 == ("1" as unknown as number));
  console.log(null == undefined, null === undefined, null == (0 as unknown as null));
  console.log(NaN === NaN, NaN == NaN, [1, 2].includes(NaN), [NaN].includes(NaN));
  console.log(0 === -0, "abc" < "abd", "a" < "B", "10" < "9");
  console.log(2 < 10, "2" < ("10" as unknown as string), 5 >= 5, 4 <= 3);
  console.log(true === (1 as unknown as boolean), false == (0 as unknown as boolean));
  console.log(null === null, undefined === undefined, (undefined as unknown) == 0);
  const a = { v: 1 };
  console.log(a === a, a !== a);
  console.log(1 < 2 && 2 < 3, 3 > 2 || false, !(1 > 2));
}

main();
