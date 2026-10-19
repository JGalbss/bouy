//! The dates of the calendars of CLDR on ICU4X's `icu_calendar`, for the
//! `Intl.DateTimeFormat` slice that the Temporal polyfill reads (contract section 17.3):
//! the polyfill computes most calendars itself and reads the Chinese, Korean, and Umm
//! al-Qura dates from `Intl.DateTimeFormat`, as V8 and `JavaScriptCore` give them from
//! ICU4C.

use icu_calendar::types::{MonthInfo, RataDie};
use icu_calendar::{AnyCalendar, AnyCalendarKind, Date, Ref};

/// The Rata Die, days from 0001-01-01, of 1970-01-01, day 0 of the epoch.
const EPOCH_RATA_DIE: i64 = 719_163;

/// A date of a calendar: the year (the related ISO year of a cyclic calendar, else the
/// year of the era), the ordinal month, whether the month is a leap month, its number in
/// the month code, and the day.
#[derive(Debug, PartialEq, Eq)]
pub struct CalendarDate {
    pub year: i32,
    pub ordinal_month: u8,
    pub month_number: u8,
    pub leap: bool,
    pub day: u8,
}

/// The date in the calendar `id` (a BCP 47 calendar type) of the day `epoch_days` after
/// 1970-01-01, or `None` for an unknown calendar. Days from Rata Die reach the years of
/// Temporal, ±271,821, which the constructors from fields of ICU4X do not.
#[must_use]
pub fn date(id: &str, epoch_days: i64) -> Option<CalendarDate> {
    let kind = match id {
        "buddhist" => AnyCalendarKind::Buddhist,
        "chinese" => AnyCalendarKind::Chinese,
        "coptic" => AnyCalendarKind::Coptic,
        "dangi" => AnyCalendarKind::Dangi,
        "ethioaa" => AnyCalendarKind::EthiopianAmeteAlem,
        "ethiopic" => AnyCalendarKind::Ethiopian,
        "gregory" => AnyCalendarKind::Gregorian,
        "hebrew" => AnyCalendarKind::Hebrew,
        "indian" => AnyCalendarKind::Indian,
        "islamic-civil" => AnyCalendarKind::HijriTabularTypeIIFriday,
        "islamic-tbla" => AnyCalendarKind::HijriTabularTypeIIThursday,
        "islamic-umalqura" => AnyCalendarKind::HijriUmmAlQura,
        "iso8601" => AnyCalendarKind::Iso,
        "japanese" => AnyCalendarKind::Japanese,
        "persian" => AnyCalendarKind::Persian,
        "roc" => AnyCalendarKind::Roc,
        _ => return None,
    };
    let calendar = AnyCalendar::new(kind);
    let local = Date::from_rata_die(RataDie::new(epoch_days + EPOCH_RATA_DIE), Ref(&calendar));
    let info: MonthInfo = local.month();
    let code = info.to_input();
    Some(CalendarDate {
        year: local.year().era_year_or_related_iso(),
        ordinal_month: info.ordinal,
        month_number: code.number(),
        leap: code.is_leap(),
        day: local.day_of_month().0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_chinese_and_umalqura_dates() {
        // 2023-02-20, day 19408, is the first day of the second month of the year related
        // to 2023.
        let chinese = date("chinese", 19_408).expect("a date");
        assert_eq!(
            (chinese.year, chinese.month_number, chinese.day),
            (2023, 2, 1)
        );
        // 2023-03-23, day 19439, is 1 Ramadan 1444.
        let hijri = date("islamic-umalqura", 19_439).expect("a date");
        assert_eq!((hijri.year, hijri.ordinal_month, hijri.day), (1444, 9, 1));
        assert_eq!(date("klingon", 0), None);
        // 275760-09-13, the last day of Temporal, is day 100,000,000.
        assert!(date("chinese", 100_000_000).is_some());
    }
}
