// Temporal: the lazy global that loads the compiled polyfill on first use, its plain types,
// Duration balancing, Instant with nanoseconds, Date.prototype.toTemporalInstant, a named
// zone across a daylight saving gap, a fixed offset zone, and the namespace. Node 25.9 has
// no Temporal, so scripts/freeze-expectations.sh runs this program with the same polyfill.
// The output leaves out the clock, the system zone, and toLocaleString.
const date = Temporal.PlainDate.from("2024-02-29");
console.log(date.toString(), date.add({ years: 1 }).toString(), date.dayOfWeek, date.inLeapYear);
console.log(date.until("2025-03-01", { largestUnit: "month" }).toString());
const time = Temporal.PlainTime.from({ hour: 23, minute: 59, second: 59, nanosecond: 1 });
console.log(time.toString(), time.add({ seconds: 1 }).toString());

const duration = Temporal.Duration.from({ hours: 25, minutes: 61 });
console.log(duration.round({ largestUnit: "day" }).toString(), duration.total("minute"));
console.log(Temporal.Duration.compare({ hours: 24 }, { days: 1 }, { relativeTo: date }));

const instant = Temporal.Instant.from("2020-01-01T00:00:00.123456789Z");
console.log(instant.epochNanoseconds, instant.epochMilliseconds, instant.toString());
console.log(new Date(Date.UTC(2026, 9, 17, 13, 5, 9, 7)).toTemporalInstant().toString());

const zoned = Temporal.ZonedDateTime.from("2021-03-14T01:30[America/New_York]");
console.log(zoned.add({ hours: 1 }).toString(), zoned.hoursInDay, zoned.offset);
const fixed = Temporal.ZonedDateTime.from("2020-06-01T12:00+05:30[+05:30]");
console.log(fixed.withTimeZone("UTC").toString(), fixed.toPlainDate().toString());

console.log(Object.prototype.toString.call(Temporal), Object.getOwnPropertyNames(Temporal).join());
const now = Temporal.Now.instant();
console.log(typeof now.epochNanoseconds, Temporal.Instant.compare(now, instant));
try {
  Temporal.PlainDate.from("2024-02-30", { overflow: "reject" });
} catch (error) {
  console.log(error instanceof RangeError);
}
