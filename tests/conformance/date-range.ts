// Dates across the whole time range, and ISO text with V8's rules: fields
// out of range are invalid, short forms are UTC, and years outside 0000 to
// 9999 print with six digits and a sign. Every line avoids the local time
// zone of the oracle.

function time(text: string): number {
  return new Date(text).getTime();
}

function main(): void {
  console.log(
    "out of range:",
    time("2020-13-01"),
    time("2020-01-32"),
    time("2020-00-10"),
    time("2020-01-00"),
  );
  console.log(
    "short forms:",
    time("2020"),
    time("2020-06"),
    time("2020-01-01T10:20Z"),
    time("+002020-01-01"),
  );
  console.log("day rolls over:", time("2020-02-30"), time("2021-02-29"));
  console.log(
    "end of day:",
    time("2020-01-01T24:00:00Z"),
    time("2020-01-01T24:00:01Z"),
    time("2020-01-01T23:60:00Z"),
  );
  console.log(
    "offsets:",
    time("2020-01-01T10:20:30+05:30"),
    time("2020-01-01T10:20:30-0530"),
    time("2020-01-01T10:20:30+25:00"),
  );
  console.log(
    "fractions:",
    time("2020-01-01T10:20:30.5Z"),
    time("2020-01-01T10:20:30.123456Z"),
    time("2020-01-01T10:20:30.Z"),
  );
  console.log(
    "letters:",
    time("2020-01-01t10:20:30z"),
    time("2020-01-01 10:20:30Z"),
    time("2020-06-15T"),
    time("20200101"),
  );
  console.log(
    "limits:",
    time("+275760-09-13T00:00:00.000Z"),
    time("+275760-09-13T00:00:00.001Z"),
    time("-000000-01-01T00:00:00Z"),
  );
  for (const ms of [
    -62198755200000, 253402300800000, 8.64e15, -8.64e15, -62135596800001, 0, -1, 951782400000,
  ]) {
    const date = new Date(ms);
    console.log(
      ms,
      date.toISOString(),
      JSON.stringify({ at: date }),
      time(date.toISOString()) === ms,
    );
  }
}

main();
