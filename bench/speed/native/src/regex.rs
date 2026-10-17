//! Regular expressions as a native built-in on the `regex` crate, which runs finite
//! automata and never backtracks. Patterns compile once into a process-wide cache. With
//! Unicode off, `\w` and `\d` are the ASCII classes, as in JavaScript without the u flag.
//! A pattern that needs backtracking, such as a backreference, fails to compile here, and
//! a real built-in would hand it to a backtracking engine.

use super::{Env, Term, enif_make_list_from_array, enif_make_sub_binary};
use regex::bytes::{Regex, RegexBuilder};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

type Cache = RwLock<HashMap<Vec<u8>, Arc<Regex>>>;

fn cache() -> &'static Cache {
    static CACHE: OnceLock<Cache> = OnceLock::new();
    CACHE.get_or_init(Cache::default)
}

/// The compiled pattern, from the cache when an earlier call compiled it.
pub fn compiled(pattern: &[u8]) -> Option<Arc<Regex>> {
    if let Some(found) = cache().read().ok()?.get(pattern) {
        return Some(Arc::clone(found));
    }
    let regex = Arc::new(
        RegexBuilder::new(std::str::from_utf8(pattern).ok()?)
            .unicode(false)
            .build()
            .ok()?,
    );
    cache()
        .write()
        .ok()?
        .insert(pattern.to_vec(), Arc::clone(&regex));
    Some(regex)
}

fn count(length: usize) -> u32 {
    u32::try_from(length).unwrap_or(u32::MAX)
}

/// `text.match(/pattern/g)`: every match, as sub-binaries of the subject.
pub unsafe fn matches(env: *mut Env, regex: &Regex, subject: Term, text: &[u8]) -> Term {
    let found: Vec<Term> = regex
        .find_iter(text)
        .map(|m| unsafe { enif_make_sub_binary(env, subject, m.start(), m.len()) })
        .collect();
    unsafe { enif_make_list_from_array(env, found.as_ptr(), count(found.len())) }
}

/// `text.matchAll(/pattern/g)` with the given groups of each match, as sub-binaries.
pub unsafe fn captures(
    env: *mut Env,
    regex: &Regex,
    subject: Term,
    text: &[u8],
    groups: &[usize],
) -> Term {
    let rows: Vec<Term> = regex
        .captures_iter(text)
        .map(|caps| {
            let cells: Vec<Term> = groups
                .iter()
                .map(|&group| {
                    let (start, length) = caps.get(group).map_or((0, 0), |m| (m.start(), m.len()));
                    unsafe { enif_make_sub_binary(env, subject, start, length) }
                })
                .collect();
            unsafe { enif_make_list_from_array(env, cells.as_ptr(), count(cells.len())) }
        })
        .collect();
    unsafe { enif_make_list_from_array(env, rows.as_ptr(), count(rows.len())) }
}
