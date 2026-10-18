// Date in UTC: Date.UTC and MakeDay overflow, the UTC getters and setters,
// toISOString with expanded years, toUTCString, toJSON, and Date.parse of
// the ISO and RFC 1123 forms. The local-time methods depend on the zone of
// the machine, so this program leaves them out.
const t = Date.UTC(2026, 9, 17, 13, 5, 9, 7);
const d = new Date(t);
console.log(t, d.toISOString(), d.toUTCString(), JSON.stringify({ d }));
console.log(
  d.getUTCFullYear(),
  d.getUTCMonth(),
  d.getUTCDate(),
  d.getUTCDay(),
  d.getUTCHours(),
  d.getUTCMilliseconds(),
);
console.log(
  Date.UTC(2026, 13, 1),
  Date.UTC(2026, -1, 31),
  Date.UTC(99),
  Date.UTC(2026, 0, 1, 25, 61, 61, 1001),
);
console.log(
  new Date(8.64e15).toISOString(),
  new Date(-8.64e15).toISOString(),
  new Date(8.64e15 + 1).getTime(),
  new Date(253402300800000).toISOString(),
);
const e = new Date(Date.UTC(2000, 0, 31));
console.log(
  e.setUTCMonth(1),
  e.toISOString(),
  e.setUTCFullYear(2001, 5, 15),
  e.setUTCHours(48),
  e.toISOString(),
);
console.log(
  Date.parse("2026-10-17T13:05:09.5Z"),
  Date.parse("2026-10-17T13:05:09+02:00"),
  Date.parse("2026-10-17"),
  Date.parse("2026-10"),
  Date.parse("+002026-10-17T00:00:00Z"),
);
console.log(
  Date.parse("Sat, 17 Oct 2026 13:05:09 GMT"),
  Date.parse("2026-02-30"),
  Date.parse("2026-10-17T24:00:00Z"),
  Date.parse("nonsense"),
);
console.log(
  new Date(NaN).getTime(),
  String(new Date(NaN)),
  new Date(NaN).toJSON(),
  Object.prototype.toString.call(d),
  typeof Date.now(),
);
try {
  new Date(NaN).toISOString();
} catch (error) {
  console.log((error as Error).name + ": " + (error as Error).message);
}
// The legacy forms of Date.parse, as V8 reads them.
console.log(
  [
    "1997-3-8 1:1:1.01",
    "+001997-03-8 11:19:20",
    "1997-03-08 11:19:10-07",
    "1997-03-08T11:19:10-07",
    "1997-3-8T11:19:20",
    "June 10, 49",
    "10 June 50",
    "1/2",
    "Jan 1 2000 10:00 GMT-08:30",
    "1/1/2000 12:30 pm",
    "(note) Jan 1 2000 (more (nested)) 10:00 Z",
    "2000 foo",
    "Tue, 01 Mar 2016 10:00:00 PST",
  ].map((text) => Date.parse(text)),
);
