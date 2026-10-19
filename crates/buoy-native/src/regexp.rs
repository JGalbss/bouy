//! The matcher of regular expressions (ECMA-262 22.2.2) as a backtracking machine with
//! its own stack, so it can stop at the end of a time slice and resume in the next call.
//!
//! `buoy_regexp_match:lower/2` gives the tree of a pattern with every character, class,
//! and escape resolved to a set of characters, so the parser, the early errors, and the
//! Unicode data stay in Erlang and keep one source. This module compiles the tree into
//! instructions and runs them over the code units of a string: one byte each (Latin-1),
//! or two bytes each, big-endian. Bun matches with the bytecode interpreter of
//! `JavaScriptCore`'s Yarr, which also reads 8-bit and 16-bit strings as they are and keeps
//! the state of the backtracking in a stack of its own; this machine follows that design.
//!
//! The instructions follow the closures of `buoy_regexp_match` step by step: a repeat
//! counts its iterations, clears the captures of its body at each one, and fails an
//! optional iteration that matches the empty string; a lookaround is atomic; a group sets
//! its capture when its body ends; a lookbehind runs its body right to left.

use std::sync::Mutex;

use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};

use crate::slice::Slice;

mod atoms {
    rustler::atoms! {
        ok, error, done, more, nomatch, overflow, undefined, infinity,
        empty, set, literal, seq, alt, group, repeat, bol, eol, boundary, look, backref, none,
        matched = "match",
    }
}

/// The deepest tree that the compiler takes; a deeper one runs on the Erlang closures. The
/// compiler recurses on a scheduler thread, whose stack is about 1 MB.
const MAX_DEPTH: usize = 200;

/// The most entries of the backtracking stack: past it, the search is a `RangeError`, as
/// V8 limits the stack of its regular expressions.
const MAX_STACK: usize = 2_000_000;

/// An unset capture.
const UNSET: (usize, usize) = (usize::MAX, usize::MAX);

/// A count without a bound.
const UNBOUNDED: usize = usize::MAX;

/// A compiled pattern.
#[derive(Debug)]
pub struct Regexp(Program);

#[rustler::resource_impl]
impl rustler::Resource for Regexp {}

/// A search between two calls.
#[derive(Debug)]
pub struct Search(Mutex<Searcher>);

#[rustler::resource_impl]
impl rustler::Resource for Search {}

/// `regexp_compile(Tree, Groups, Unicode)`: `{ok, Program}`, or `error` for a tree that
/// this matcher does not take.
#[rustler::nif]
fn regexp_compile<'a>(env: Env<'a>, tree: Term<'a>, groups: usize, unicode: bool) -> Term<'a> {
    match decode(tree, 0).map(|node| Program::new(&node, groups, unicode)) {
        Some(program) => (atoms::ok(), ResourceArc::new(Regexp(program))).encode(env),
        None => atoms::error().encode(env),
    }
}

/// `regexp_search(Program, Text, Wide, From, Sticky, State)`: the first match at or after
/// `From`, or only at `From` when `Sticky`: `{match, Index, End, Captures}`, `nomatch`,
/// `{more, State}` when the slice ended first, or `overflow`.
#[rustler::nif]
fn regexp_search<'a>(
    env: Env<'a>,
    regexp: Term<'a>,
    text: Binary<'a>,
    wide: bool,
    from: usize,
    sticky: bool,
    state: Term<'a>,
) -> NifResult<Term<'a>> {
    let regexp: ResourceArc<Regexp> = regexp.decode()?;
    let program = &regexp.0;
    let mut searcher = resume(state, from, program)?;
    let mut slice = Slice::new();
    let bytes = text.as_slice();
    let outcome = if wide {
        searcher.run(program, &Utf16(bytes), sticky, env, &mut slice)
    } else {
        searcher.run(program, &Latin1(bytes), sticky, env, &mut slice)
    };
    Ok(match outcome {
        Outcome::Match(index, end) => match_term(env, index, end, &searcher.vm.captures),
        Outcome::NoMatch => atoms::nomatch().encode(env),
        Outcome::Overflow => atoms::overflow().encode(env),
        Outcome::Paused => {
            let resource = ResourceArc::new(Search(Mutex::new(searcher)));
            (atoms::more(), resource).encode(env)
        }
    })
}

/// `regexp_search_all(Program, Text, Wide, Sticky, State)`: every match from index 0, as
/// `buoy_regexp_match:search_all/3` finds them: `{done, Matches}`, `{more, State, Matches}`
/// with the matches of this slice, or `overflow`.
#[rustler::nif]
fn regexp_search_all<'a>(
    env: Env<'a>,
    regexp: Term<'a>,
    text: Binary<'a>,
    wide: bool,
    sticky: bool,
    state: Term<'a>,
) -> NifResult<Term<'a>> {
    let regexp: ResourceArc<Regexp> = regexp.decode()?;
    let program = &regexp.0;
    let mut searcher = resume(state, 0, program)?;
    let mut slice = Slice::new();
    let mut found = Vec::new();
    let bytes = text.as_slice();
    let outcome = if wide {
        searcher.run_all(program, &Utf16(bytes), sticky, env, &mut slice, &mut found)
    } else {
        searcher.run_all(program, &Latin1(bytes), sticky, env, &mut slice, &mut found)
    };
    Ok(match outcome {
        Outcome::Overflow => atoms::overflow().encode(env),
        Outcome::Paused => {
            let resource = ResourceArc::new(Search(Mutex::new(searcher)));
            (atoms::more(), resource, found).encode(env)
        }
        Outcome::Match(..) | Outcome::NoMatch => (atoms::done(), found).encode(env),
    })
}

/// The search of a `more` result, or a new one from `from`.
fn resume(state: Term, from: usize, program: &Program) -> NifResult<Searcher> {
    match state.decode::<ResourceArc<Search>>() {
        Ok(resource) => {
            let mut held = resource.0.lock().map_err(|_| rustler::Error::BadArg)?;
            Ok(std::mem::take(&mut *held))
        }
        Err(_) => Ok(Searcher::new(from, program)),
    }
}

/// `{match, Index, End, Captures}`, with `undefined` or `{Start, End}` for each group.
fn match_term<'a>(env: Env<'a>, index: usize, end: usize, captures: &[(usize, usize)]) -> Term<'a> {
    let captures: Vec<Term<'a>> = captures
        .iter()
        .map(|&capture| {
            if capture == UNSET {
                atoms::undefined().encode(env)
            } else {
                capture.encode(env)
            }
        })
        .collect();
    (atoms::matched(), index, end, make_tuple(env, &captures)).encode(env)
}

/// The tree of `buoy_regexp_match:lower/2`.
#[derive(Debug)]
enum Node {
    Empty,
    Set(CharSet),
    Literal(Vec<u16>),
    Seq(Vec<Node>),
    Alt(Vec<Node>),
    Group(usize, Box<Node>),
    Repeat {
        min: usize,
        max: usize,
        greedy: bool,
        node: Box<Node>,
        paren_index: usize,
        paren_count: usize,
    },
    Bol(bool),
    Eol(bool),
    Boundary(bool, CharSet),
    Look {
        ahead: bool,
        positive: bool,
        node: Box<Node>,
    },
    Backref(Vec<usize>, Option<Fold>),
}

fn decode(term: Term, depth: usize) -> Option<Node> {
    if depth > MAX_DEPTH {
        return None;
    }
    if let Ok(atom) = term.decode::<Atom>() {
        return (atom == atoms::empty()).then_some(Node::Empty);
    }
    let parts = get_tuple(term).ok()?;
    let tag = parts.first()?.decode::<Atom>().ok()?;
    let nodes = |term: Term| -> Option<Vec<Node>> {
        term.decode::<Vec<Term>>()
            .ok()?
            .into_iter()
            .map(|node| decode(node, depth + 1))
            .collect()
    };
    let node = match parts.as_slice() {
        [_, ranges] if tag == atoms::set() => Node::Set(CharSet::new(ranges.decode().ok()?)),
        [_, units] if tag == atoms::literal() => Node::Literal(units.decode().ok()?),
        [_, items] if tag == atoms::seq() => Node::Seq(nodes(*items)?),
        [_, items] if tag == atoms::alt() => Node::Alt(nodes(*items)?),
        [_, index, node] if tag == atoms::group() => {
            Node::Group(index.decode().ok()?, Box::new(decode(*node, depth + 1)?))
        }
        [_, min, max, greedy, node, paren_index, paren_count] if tag == atoms::repeat() => {
            Node::Repeat {
                min: min.decode().ok()?,
                max: match max.decode::<Atom>() {
                    Ok(atom) if atom == atoms::infinity() => UNBOUNDED,
                    _ => max.decode().ok()?,
                },
                greedy: greedy.decode().ok()?,
                node: Box::new(decode(*node, depth + 1)?),
                paren_index: paren_index.decode().ok()?,
                paren_count: paren_count.decode().ok()?,
            }
        }
        [_, multiline] if tag == atoms::bol() => Node::Bol(multiline.decode().ok()?),
        [_, multiline] if tag == atoms::eol() => Node::Eol(multiline.decode().ok()?),
        [_, wanted, ranges] if tag == atoms::boundary() => {
            Node::Boundary(wanted.decode().ok()?, CharSet::new(ranges.decode().ok()?))
        }
        [_, ahead, positive, node] if tag == atoms::look() => Node::Look {
            ahead: ahead.decode().ok()?,
            positive: positive.decode().ok()?,
            node: Box::new(decode(*node, depth + 1)?),
        },
        [_, indexes, table] if tag == atoms::backref() => {
            let fold = match table.decode::<Atom>() {
                Ok(atom) if atom == atoms::none() => None,
                _ => Some(Fold::new(table.decode().ok()?)),
            };
            Node::Backref(indexes.decode().ok()?, fold)
        }
        _ => return None,
    };
    Some(node)
}

/// A set of characters: sorted, disjoint ranges, and a bitmap of the first 256.
#[derive(Debug, Clone, Default)]
struct CharSet {
    ranges: Vec<(u32, u32)>,
    low: [u64; 4],
}

impl CharSet {
    fn new(mut ranges: Vec<(u32, u32)>) -> Self {
        ranges.sort_unstable();
        let mut merged: Vec<(u32, u32)> = Vec::with_capacity(ranges.len());
        for (low, high) in ranges {
            match merged.last_mut() {
                Some(last) if low <= last.1.saturating_add(1) => last.1 = last.1.max(high),
                _ => merged.push((low, high)),
            }
        }
        let mut low = [0_u64; 4];
        for &(from, to) in &merged {
            for char in from..=to.min(255) {
                low[(char >> 6) as usize] |= 1 << (char & 63);
            }
        }
        Self {
            ranges: merged,
            low,
        }
    }

    fn contains(&self, char: u32) -> bool {
        if char < 256 {
            return self.low[(char >> 6) as usize] >> (char & 63) & 1 != 0;
        }
        self.ranges
            .binary_search_by(|&(low, high)| {
                if high < char {
                    std::cmp::Ordering::Less
                } else if low > char {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .is_ok()
    }

    fn union(&self, other: &Self) -> Self {
        Self::new(self.ranges.iter().chain(&other.ranges).copied().collect())
    }

    fn has_astral(&self) -> bool {
        self.ranges.last().is_some_and(|&(_, high)| high > 0xFFFF)
    }

    fn is_disjoint(&self, other: &Self) -> bool {
        let (mut left, mut right) = (
            self.ranges.iter().peekable(),
            other.ranges.iter().peekable(),
        );
        while let (Some(&&(a_low, a_high)), Some(&&(b_low, b_high))) = (left.peek(), right.peek()) {
            if a_high < b_low {
                left.next();
            } else if b_high < a_low {
                right.next();
            } else {
                return false;
            }
        }
        true
    }
}

/// What follows a node up to the end of the pattern, so a greedy repeat of one character
/// can skip its backtracking when no shorter run can be followed (auto-possessive, as
/// PCRE does it): the end of the pattern, a node that must start with a character of a
/// set, or something else.
#[derive(Debug, Clone)]
enum Follow {
    End,
    Chars(CharSet),
    Unknown,
}

impl Follow {
    /// Whether a greedy repeat of `set` before this needs no backtracking: a shorter run
    /// stops before a character of `set`, which what follows cannot start with.
    fn allows(&self, set: &CharSet) -> bool {
        match self {
            Self::End => true,
            Self::Chars(next) => set.is_disjoint(next),
            Self::Unknown => false,
        }
    }
}

/// Canonicalize for a backreference with the i flag: each character that shares its
/// canonical value with another, sorted.
#[derive(Debug)]
struct Fold(Vec<(u32, u32)>);

impl Fold {
    fn new(mut pairs: Vec<(u32, u32)>) -> Self {
        pairs.sort_unstable();
        Self(pairs)
    }

    fn canonical(&self, char: u32) -> u32 {
        self.0
            .binary_search_by_key(&char, |&(from, _)| from)
            .map_or(char, |found| self.0[found].1)
    }
}

#[derive(Debug, Clone, Copy)]
enum Insn {
    /// One character of a set.
    Char {
        set: usize,
        back: bool,
    },
    /// A run of code units.
    Literal {
        literal: usize,
        back: bool,
    },
    /// A repeat of one character of a set: it scans, then gives back or takes one more.
    Star {
        set: usize,
        min: usize,
        max: usize,
        greedy: bool,
        possessive: bool,
        back: bool,
    },
    /// Go on at the next instruction, and at `next` on backtracking.
    Split {
        next: usize,
    },
    Jump(usize),
    GroupStart {
        group: usize,
    },
    GroupEnd {
        group: usize,
        back: bool,
    },
    RepeatInit {
        counter: usize,
    },
    /// The choice of `RepeatMatcher`; the body starts at the next instruction.
    RepeatLoop {
        counter: usize,
        min: usize,
        max: usize,
        greedy: bool,
        exit: usize,
    },
    RepeatBody {
        counter: usize,
        clear_from: usize,
        clear_count: usize,
    },
    RepeatEnd {
        counter: usize,
        min: usize,
        loop_pc: usize,
    },
    Bol(bool),
    Eol(bool),
    Boundary {
        wanted: bool,
        set: usize,
    },
    LookStart {
        positive: bool,
        end: usize,
    },
    LookEnd,
    Backref {
        groups: usize,
        fold: Option<usize>,
        back: bool,
    },
    Match,
}

#[derive(Debug)]
struct Program {
    insns: Vec<Insn>,
    sets: Vec<CharSet>,
    literals: Vec<Vec<u16>>,
    backrefs: Vec<Vec<usize>>,
    folds: Vec<Fold>,
    groups: usize,
    counters: usize,
    unicode: bool,
    /// The characters that a match can start with, when the pattern cannot match empty.
    first: Option<CharSet>,
}

impl Program {
    fn new(node: &Node, groups: usize, unicode: bool) -> Self {
        let mut program = Self {
            insns: Vec::new(),
            sets: Vec::new(),
            literals: Vec::new(),
            backrefs: Vec::new(),
            folds: Vec::new(),
            groups,
            counters: 0,
            unicode,
            first: None,
        };
        program.emit(node, false, &Follow::End);
        program.insns.push(Insn::Match);
        program.first = match first(node) {
            Some((set, false)) => Some(set),
            _ => None,
        };
        program
    }

    fn push(&mut self, insn: Insn) -> usize {
        self.insns.push(insn);
        self.insns.len() - 1
    }

    fn set(&mut self, set: &CharSet) -> usize {
        self.sets.push(set.clone());
        self.sets.len() - 1
    }

    fn emit(&mut self, node: &Node, back: bool, follow: &Follow) {
        match node {
            Node::Empty => {}
            Node::Set(set) => {
                let set = self.set(set);
                self.push(Insn::Char { set, back });
            }
            Node::Literal(units) => {
                self.literals.push(units.clone());
                let literal = self.literals.len() - 1;
                self.push(Insn::Literal { literal, back });
            }
            Node::Seq(nodes) if back => nodes
                .iter()
                .rev()
                .for_each(|node| self.emit(node, back, &Follow::Unknown)),
            Node::Seq(nodes) => {
                for (index, node) in nodes.iter().enumerate() {
                    let rest = &nodes[index + 1..];
                    let next = if rest.is_empty() {
                        follow.clone()
                    } else if matches!(node, Node::Repeat { .. } | Node::Group(..) | Node::Alt(_)) {
                        match first_seq(rest) {
                            Some((set, false)) => Follow::Chars(set),
                            _ => Follow::Unknown,
                        }
                    } else {
                        Follow::Unknown
                    };
                    self.emit(node, back, &next);
                }
            }
            Node::Alt(nodes) => self.alternatives(nodes, back, follow),
            Node::Group(index, node) => {
                let group = index.saturating_sub(1);
                self.push(Insn::GroupStart { group });
                self.emit(node, back, follow);
                self.push(Insn::GroupEnd { group, back });
            }
            Node::Repeat {
                min,
                max,
                greedy,
                node,
                paren_index,
                paren_count,
            } => self.repeat(
                (*min, *max, *greedy),
                node,
                (*paren_index, *paren_count),
                back,
                follow,
            ),
            Node::Bol(multiline) => {
                self.push(Insn::Bol(*multiline));
            }
            Node::Eol(multiline) => {
                self.push(Insn::Eol(*multiline));
            }
            Node::Boundary(wanted, set) => {
                let set = self.set(set);
                self.push(Insn::Boundary {
                    wanted: *wanted,
                    set,
                });
            }
            Node::Look {
                ahead,
                positive,
                node,
            } => {
                let start = self.push(Insn::LookStart {
                    positive: *positive,
                    end: 0,
                });
                self.emit(node, !ahead, &Follow::Unknown);
                self.push(Insn::LookEnd);
                let end = self.insns.len();
                self.insns[start] = Insn::LookStart {
                    positive: *positive,
                    end,
                };
            }
            Node::Backref(indexes, fold) => {
                self.backrefs.push(
                    indexes
                        .iter()
                        .map(|index| index.saturating_sub(1))
                        .collect(),
                );
                let groups = self.backrefs.len() - 1;
                let fold = fold.as_ref().map(|fold| {
                    self.folds.push(Fold(fold.0.clone()));
                    self.folds.len() - 1
                });
                self.push(Insn::Backref { groups, fold, back });
            }
        }
    }

    fn alternatives(&mut self, nodes: &[Node], back: bool, follow: &Follow) {
        let mut jumps = Vec::new();
        for (index, node) in nodes.iter().enumerate() {
            if index + 1 == nodes.len() {
                self.emit(node, back, follow);
                break;
            }
            let split = self.push(Insn::Split { next: 0 });
            self.emit(node, back, follow);
            jumps.push(self.push(Insn::Jump(0)));
            let next = self.insns.len();
            self.insns[split] = Insn::Split { next };
        }
        let end = self.insns.len();
        for jump in jumps {
            self.insns[jump] = Insn::Jump(end);
        }
    }

    fn repeat(
        &mut self,
        (min, max, greedy): (usize, usize, bool),
        node: &Node,
        (clear_from, clear_count): (usize, usize),
        back: bool,
        follow: &Follow,
    ) {
        if max == 0 {
            return;
        }
        if let Node::Set(chars) = node {
            let possessive = greedy && !back && follow.allows(chars);
            let set = self.set(chars);
            self.push(Insn::Star {
                set,
                min,
                max,
                greedy,
                possessive,
                back,
            });
            return;
        }
        let counter = self.counters;
        self.counters += 1;
        self.push(Insn::RepeatInit { counter });
        let loop_pc = self.push(Insn::RepeatLoop {
            counter,
            min,
            max,
            greedy,
            exit: 0,
        });
        self.push(Insn::RepeatBody {
            counter,
            clear_from,
            clear_count,
        });
        self.emit(node, back, &Follow::Unknown);
        self.push(Insn::RepeatEnd {
            counter,
            min,
            loop_pc,
        });
        let exit = self.insns.len();
        self.insns[loop_pc] = Insn::RepeatLoop {
            counter,
            min,
            max,
            greedy,
            exit,
        };
    }
}

/// The characters that a match of the node can start with, and whether it can match the
/// empty string; `None` when any character can start it.
fn first(node: &Node) -> Option<(CharSet, bool)> {
    match node {
        Node::Empty | Node::Bol(_) | Node::Eol(_) | Node::Boundary(..) => {
            Some((CharSet::default(), true))
        }
        Node::Set(set) => Some((set.clone(), false)),
        // The first unit, and the code point of a surrogate pair, which a search with the
        // u or v flag reads as one character.
        Node::Literal(units) => Some(match units.as_slice() {
            [] => (CharSet::default(), true),
            &[high, low, ..] if is_high(u32::from(high)) && is_low(u32::from(low)) => {
                let point = pair(u32::from(high), u32::from(low));
                (
                    CharSet::new(vec![(u32::from(high), u32::from(high)), (point, point)]),
                    false,
                )
            }
            &[unit, ..] => (
                CharSet::new(vec![(u32::from(unit), u32::from(unit))]),
                false,
            ),
        }),
        Node::Seq(nodes) => first_seq(nodes),
        Node::Alt(nodes) => {
            nodes
                .iter()
                .try_fold((CharSet::default(), false), |(set, nullable), node| {
                    let (more, empty) = first(node)?;
                    Some((set.union(&more), nullable || empty))
                })
        }
        Node::Group(_, node) => first(node),
        Node::Repeat { min, node, .. } => {
            let (set, nullable) = first(node)?;
            Some((set, nullable || *min == 0))
        }
        Node::Look { .. } | Node::Backref(..) => None,
    }
}

fn first_seq(nodes: &[Node]) -> Option<(CharSet, bool)> {
    let mut set = CharSet::default();
    for node in nodes {
        let (more, nullable) = first(node)?;
        set = set.union(&more);
        if !nullable {
            return Some((set, false));
        }
    }
    Some((set, true))
}

/// The code units of a string.
trait Input {
    fn len(&self) -> usize;
    fn unit(&self, index: usize) -> u32;
}

/// One byte for each code unit.
struct Latin1<'a>(&'a [u8]);

/// Two bytes for each code unit, big-endian.
struct Utf16<'a>(&'a [u8]);

impl Input for Latin1<'_> {
    fn len(&self) -> usize {
        self.0.len()
    }

    fn unit(&self, index: usize) -> u32 {
        self.0.get(index).copied().map_or(0, u32::from)
    }
}

impl Input for Utf16<'_> {
    fn len(&self) -> usize {
        self.0.len() / 2
    }

    fn unit(&self, index: usize) -> u32 {
        match self.0.get(2 * index..2 * index + 2) {
            Some(&[high, low]) => u32::from(u16::from_be_bytes([high, low])),
            _ => 0,
        }
    }
}

fn is_high(unit: u32) -> bool {
    (0xD800..=0xDBFF).contains(&unit)
}

fn is_low(unit: u32) -> bool {
    (0xDC00..=0xDFFF).contains(&unit)
}

fn is_line_terminator(unit: u32) -> bool {
    matches!(unit, 0x0A | 0x0D | 0x2028 | 0x2029)
}

/// The character at `pos` and the position after it, or before `pos` and the position
/// before it when `back`. With `unicode` a surrogate pair is one character.
fn read<I: Input>(input: &I, pos: usize, back: bool, unicode: bool) -> Option<(u32, usize)> {
    if back {
        if pos == 0 {
            return None;
        }
        let unit = input.unit(pos - 1);
        if unicode && is_low(unit) && pos >= 2 {
            let high = input.unit(pos - 2);
            if is_high(high) {
                return Some((pair(high, unit), pos - 2));
            }
        }
        return Some((unit, pos - 1));
    }
    if pos >= input.len() {
        return None;
    }
    let unit = input.unit(pos);
    if unicode && is_high(unit) && pos + 1 < input.len() {
        let low = input.unit(pos + 1);
        if is_low(low) {
            return Some((pair(unit, low), pos + 2));
        }
    }
    Some((unit, pos + 1))
}

fn pair(high: u32, low: u32) -> u32 {
    0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
}

/// `AdvanceStringIndex`.
fn advance<I: Input>(input: &I, pos: usize, unicode: bool) -> usize {
    if unicode && pos + 1 < input.len() && is_high(input.unit(pos)) && is_low(input.unit(pos + 1)) {
        pos + 2
    } else {
        pos + 1
    }
}

/// The index of the character that holds the code unit at `pos`.
fn character_start<I: Input>(input: &I, pos: usize) -> usize {
    if pos > 0 && pos < input.len() && is_low(input.unit(pos)) && is_high(input.unit(pos - 1)) {
        pos - 1
    } else {
        pos
    }
}

/// An entry of the backtracking stack: a choice to resume, or a write to undo.
#[derive(Debug, Clone, Copy)]
enum Backtrack {
    Branch {
        pc: usize,
        pos: usize,
    },
    Capture {
        group: usize,
        old: (usize, usize),
    },
    GroupStart {
        group: usize,
        old: usize,
    },
    Counter {
        counter: usize,
        count: usize,
        start: usize,
    },
    /// A greedy repeat of one character at `pos`, which gives one back down to `stop`.
    Retreat {
        pc: usize,
        pos: usize,
        stop: usize,
        back: bool,
    },
    /// A lazy repeat of one character at `pos`, which takes one more while `left`.
    Lazy {
        pc: usize,
        pos: usize,
        left: usize,
        set: usize,
        back: bool,
    },
    Look {
        pos: usize,
        positive: bool,
        end: usize,
    },
}

impl Backtrack {
    fn is_undo(self) -> bool {
        matches!(
            self,
            Self::Capture { .. } | Self::GroupStart { .. } | Self::Counter { .. }
        )
    }
}

/// The state of one match attempt.
#[derive(Debug, Default)]
struct Vm {
    pc: usize,
    pos: usize,
    captures: Vec<(usize, usize)>,
    group_starts: Vec<usize>,
    counts: Vec<usize>,
    iteration_starts: Vec<usize>,
    stack: Vec<Backtrack>,
}

enum Run {
    Matched(usize),
    Failed,
    Paused,
    Overflow,
}

impl Vm {
    fn reset(&mut self, program: &Program, pos: usize) {
        self.pc = 0;
        self.pos = pos;
        self.captures.clear();
        self.captures.resize(program.groups, UNSET);
        self.group_starts.clear();
        self.group_starts.resize(program.groups, 0);
        self.counts.clear();
        self.counts.resize(program.counters, 0);
        self.iteration_starts.clear();
        self.iteration_starts.resize(program.counters, 0);
        self.stack.clear();
    }

    fn run<I: Input>(&mut self, program: &Program, input: &I, env: Env, slice: &mut Slice) -> Run {
        let mut work = 0;
        loop {
            work += 1;
            if work >= 512 {
                if slice.is_over(env, work) {
                    return Run::Paused;
                }
                work = 0;
            }
            let ok = match program.insns[self.pc] {
                Insn::Match => return Run::Matched(self.pos),
                insn => self.step(insn, program, input, &mut work),
            };
            if !ok && !self.backtrack(program, input) {
                return Run::Failed;
            }
            if self.stack.len() > MAX_STACK {
                return Run::Overflow;
            }
        }
    }

    /// Runs one instruction: whether it matched.
    fn step<I: Input>(
        &mut self,
        insn: Insn,
        program: &Program,
        input: &I,
        work: &mut usize,
    ) -> bool {
        match insn {
            Insn::Char { .. } | Insn::Literal { .. } | Insn::Star { .. } => {
                self.consume(insn, program, input, work)
            }
            Insn::Split { .. }
            | Insn::Jump(_)
            | Insn::GroupStart { .. }
            | Insn::GroupEnd { .. }
            | Insn::RepeatInit { .. }
            | Insn::RepeatLoop { .. }
            | Insn::RepeatBody { .. }
            | Insn::RepeatEnd { .. } => self.control(insn),
            _ => self.assert(insn, program, input, work),
        }
    }

    /// An instruction that reads characters.
    fn consume<I: Input>(
        &mut self,
        insn: Insn,
        program: &Program,
        input: &I,
        work: &mut usize,
    ) -> bool {
        match insn {
            Insn::Char { set, back } => match read(input, self.pos, back, program.unicode) {
                Some((char, next)) if program.sets[set].contains(char) => {
                    self.pos = next;
                    self.pc += 1;
                    true
                }
                _ => false,
            },
            Insn::Literal { literal, back } => {
                let units = &program.literals[literal];
                *work += units.len();
                let start = if back {
                    match self.pos.checked_sub(units.len()) {
                        Some(start) => start,
                        None => return false,
                    }
                } else {
                    self.pos
                };
                if start + units.len() > input.len()
                    || !units
                        .iter()
                        .enumerate()
                        .all(|(offset, &unit)| input.unit(start + offset) == u32::from(unit))
                {
                    return false;
                }
                self.pos = if back { start } else { start + units.len() };
                self.pc += 1;
                true
            }
            Insn::Star {
                set,
                min,
                max,
                greedy,
                possessive,
                back,
            } => self.star(
                program,
                input,
                (set, min, max, greedy, back),
                possessive,
                work,
            ),
            _ => false,
        }
    }

    /// An instruction of the control flow, the groups, and the repeats.
    fn control(&mut self, insn: Insn) -> bool {
        match insn {
            Insn::Split { next } => {
                self.stack.push(Backtrack::Branch {
                    pc: next,
                    pos: self.pos,
                });
                self.pc += 1;
            }
            Insn::Jump(target) => self.pc = target,
            Insn::GroupStart { group } => {
                self.stack.push(Backtrack::GroupStart {
                    group,
                    old: self.group_starts[group],
                });
                self.group_starts[group] = self.pos;
                self.pc += 1;
            }
            Insn::GroupEnd { group, back } => {
                self.stack.push(Backtrack::Capture {
                    group,
                    old: self.captures[group],
                });
                let start = self.group_starts[group];
                self.captures[group] = if back {
                    (self.pos, start)
                } else {
                    (start, self.pos)
                };
                self.pc += 1;
            }
            Insn::RepeatInit { counter } => {
                self.save_counter(counter);
                self.counts[counter] = 0;
                self.pc += 1;
            }
            Insn::RepeatLoop {
                counter,
                min,
                max,
                greedy,
                exit,
            } => self.repeat_choice(counter, min, max, greedy, exit),
            Insn::RepeatBody {
                counter,
                clear_from,
                clear_count,
            } => {
                self.save_counter(counter);
                self.iteration_starts[counter] = self.pos;
                for group in clear_from..(clear_from + clear_count).min(self.captures.len()) {
                    if self.captures[group] != UNSET {
                        self.stack.push(Backtrack::Capture {
                            group,
                            old: self.captures[group],
                        });
                        self.captures[group] = UNSET;
                    }
                }
                self.pc += 1;
            }
            Insn::RepeatEnd {
                counter,
                min,
                loop_pc,
            } => {
                let count = self.counts[counter];
                if count >= min && self.pos == self.iteration_starts[counter] {
                    return false;
                }
                self.save_counter(counter);
                self.counts[counter] = count + 1;
                self.pc = loop_pc;
            }
            _ => return false,
        }
        true
    }

    /// `RepeatMatcher`: the iteration that must come, or the choice between another
    /// iteration and the rest of the pattern.
    fn repeat_choice(&mut self, counter: usize, min: usize, max: usize, greedy: bool, exit: usize) {
        let count = self.counts[counter];
        if count >= max {
            self.pc = exit;
        } else if count < min {
            self.pc += 1;
        } else if greedy {
            self.stack.push(Backtrack::Branch {
                pc: exit,
                pos: self.pos,
            });
            self.pc += 1;
        } else {
            self.stack.push(Backtrack::Branch {
                pc: self.pc + 1,
                pos: self.pos,
            });
            self.pc = exit;
        }
    }

    /// An assertion, a lookaround, or a backreference.
    fn assert<I: Input>(
        &mut self,
        insn: Insn,
        program: &Program,
        input: &I,
        work: &mut usize,
    ) -> bool {
        let ok = match insn {
            Insn::Bol(multiline) => {
                self.pos == 0 || (multiline && is_line_terminator(input.unit(self.pos - 1)))
            }
            Insn::Eol(multiline) => {
                self.pos == input.len()
                    || (multiline
                        && self.pos < input.len()
                        && is_line_terminator(input.unit(self.pos)))
            }
            Insn::Boundary { wanted, set } => {
                let chars = &program.sets[set];
                let before = self.pos > 0 && chars.contains(input.unit(self.pos - 1));
                let after = self.pos < input.len() && chars.contains(input.unit(self.pos));
                (before != after) == wanted
            }
            Insn::LookStart { positive, end } => {
                self.stack.push(Backtrack::Look {
                    pos: self.pos,
                    positive,
                    end,
                });
                true
            }
            Insn::LookEnd => return self.look_end(),
            Insn::Backref { groups, fold, back } => {
                return self.backref(program, input, &program.backrefs[groups], fold, back, work);
            }
            _ => false,
        };
        self.pc += 1;
        ok
    }

    fn save_counter(&mut self, counter: usize) {
        self.stack.push(Backtrack::Counter {
            counter,
            count: self.counts[counter],
            start: self.iteration_starts[counter],
        });
    }

    fn star<I: Input>(
        &mut self,
        program: &Program,
        input: &I,
        (set, min, max, greedy, back): (usize, usize, usize, bool, bool),
        possessive: bool,
        work: &mut usize,
    ) -> bool {
        let unicode = program.unicode;
        let chars = &program.sets[set];
        let mut pos = self.pos;
        for _ in 0..min {
            match read(input, pos, back, unicode) {
                Some((char, next)) if chars.contains(char) => pos = next,
                _ => return false,
            }
        }
        *work += min;
        let left = if max == UNBOUNDED {
            UNBOUNDED
        } else {
            max - min
        };
        if greedy {
            let stop = pos;
            let mut taken = 0;
            while taken < left {
                match read(input, pos, back, unicode) {
                    Some((char, next)) if chars.contains(char) => pos = next,
                    _ => break,
                }
                taken += 1;
            }
            *work += taken;
            if pos != stop && !possessive {
                self.stack.push(Backtrack::Retreat {
                    pc: self.pc + 1,
                    pos,
                    stop,
                    back,
                });
            }
        } else if left > 0 {
            self.stack.push(Backtrack::Lazy {
                pc: self.pc + 1,
                pos,
                left,
                set,
                back,
            });
        }
        self.pos = pos;
        self.pc += 1;
        true
    }

    /// The body of a lookaround matched.
    fn look_end(&mut self) -> bool {
        let Some(index) = self
            .stack
            .iter()
            .rposition(|entry| matches!(entry, Backtrack::Look { .. }))
        else {
            return false;
        };
        let Backtrack::Look { pos, positive, end } = self.stack[index] else {
            return false;
        };
        if positive {
            // Atomic: the choices of the body go, and its writes stay to undo later.
            let body = self.stack.split_off(index + 1);
            self.stack.pop();
            self.stack
                .extend(body.into_iter().filter(|entry| entry.is_undo()));
            self.pos = pos;
            self.pc = end;
            return true;
        }
        while self.stack.len() > index {
            if let Some(entry) = self.stack.pop() {
                self.undo(entry);
            }
        }
        false
    }

    fn backref<I: Input>(
        &mut self,
        program: &Program,
        input: &I,
        groups: &[usize],
        fold: Option<usize>,
        back: bool,
        work: &mut usize,
    ) -> bool {
        let Some(&(start, end)) = groups
            .iter()
            .map(|&group| &self.captures[group])
            .find(|&&capture| capture != UNSET)
        else {
            self.pc += 1;
            return true;
        };
        *work += end - start;
        let fold = fold.map(|fold| &program.folds[fold]);
        let same = |a: u32, b: u32| {
            a == b || fold.is_some_and(|fold| fold.canonical(a) == fold.canonical(b))
        };
        let next = if program.unicode {
            same_characters(input, (start, end), self.pos, back, &same)
        } else {
            same_units(input, (start, end), self.pos, back, &same)
        };
        match next {
            Some(pos) => {
                self.pos = pos;
                self.pc += 1;
                true
            }
            None => false,
        }
    }

    /// Resumes the last choice, undoing the writes after it: false when none is left.
    fn backtrack<I: Input>(&mut self, program: &Program, input: &I) -> bool {
        while let Some(entry) = self.stack.pop() {
            match entry {
                Backtrack::Branch { pc, pos } => {
                    self.pc = pc;
                    self.pos = pos;
                    return true;
                }
                Backtrack::Retreat {
                    pc,
                    pos,
                    stop,
                    back,
                } => {
                    let previous = retreat(input, pos, stop, back, program.unicode);
                    if previous != stop {
                        self.stack.push(Backtrack::Retreat {
                            pc,
                            pos: previous,
                            stop,
                            back,
                        });
                    }
                    self.pc = pc;
                    self.pos = previous;
                    return true;
                }
                Backtrack::Lazy {
                    pc,
                    pos,
                    left,
                    set,
                    back,
                } => {
                    if let Some((char, next)) = read(input, pos, back, program.unicode)
                        && program.sets[set].contains(char)
                    {
                        let left = if left == UNBOUNDED {
                            UNBOUNDED
                        } else {
                            left - 1
                        };
                        if left > 0 {
                            self.stack.push(Backtrack::Lazy {
                                pc,
                                pos: next,
                                left,
                                set,
                                back,
                            });
                        }
                        self.pc = pc;
                        self.pos = next;
                        return true;
                    }
                }
                Backtrack::Look {
                    pos,
                    positive: false,
                    end,
                } => {
                    self.pc = end;
                    self.pos = pos;
                    return true;
                }
                undo => self.undo(undo),
            }
        }
        false
    }

    fn undo(&mut self, entry: Backtrack) {
        match entry {
            Backtrack::Capture { group, old } => self.captures[group] = old,
            Backtrack::GroupStart { group, old } => self.group_starts[group] = old,
            Backtrack::Counter {
                counter,
                count,
                start,
            } => {
                self.counts[counter] = count;
                self.iteration_starts[counter] = start;
            }
            _ => {}
        }
    }
}

/// One character back toward `stop` from the end of a greedy scan.
fn retreat<I: Input>(input: &I, pos: usize, stop: usize, back: bool, unicode: bool) -> usize {
    if back {
        let next = read(input, pos, false, unicode).map_or(pos + 1, |(_, next)| next);
        next.min(stop)
    } else {
        let previous =
            read(input, pos, true, unicode).map_or(pos.saturating_sub(1), |(_, previous)| previous);
        previous.max(stop)
    }
}

/// `BackreferenceMatcher` on code units: the position after the copy of the capture at
/// `pos`, or before it when `back`.
fn same_units<I: Input>(
    input: &I,
    (start, end): (usize, usize),
    pos: usize,
    back: bool,
    same: &dyn Fn(u32, u32) -> bool,
) -> Option<usize> {
    let length = end - start;
    let from = if back { pos.checked_sub(length)? } else { pos };
    if from + length > input.len() {
        return None;
    }
    (0..length)
        .all(|offset| same(input.unit(start + offset), input.unit(from + offset)))
        .then_some(if back { from } else { from + length })
}

/// `BackreferenceMatcher` on code points, with a surrogate pair as one character.
fn same_characters<I: Input>(
    input: &I,
    (start, end): (usize, usize),
    pos: usize,
    back: bool,
    same: &dyn Fn(u32, u32) -> bool,
) -> Option<usize> {
    let (mut captured, mut at) = (if back { end } else { start }, pos);
    loop {
        let done = if back {
            captured <= start
        } else {
            captured >= end
        };
        if done {
            return Some(at);
        }
        let (a, next_captured) = read(input, captured, back, true)?;
        let (b, next_at) = read(input, at, back, true)?;
        if !same(a, b) {
            return None;
        }
        captured = next_captured;
        at = next_at;
    }
}

enum Outcome {
    Match(usize, usize),
    NoMatch,
    Paused,
    Overflow,
}

/// A search: the index of the current attempt, and its machine.
#[derive(Debug, Default)]
struct Searcher {
    at: usize,
    attempting: bool,
    vm: Vm,
}

impl Searcher {
    fn new(from: usize, program: &Program) -> Self {
        let mut vm = Vm::default();
        vm.reset(program, from);
        Self {
            at: from,
            attempting: false,
            vm,
        }
    }

    fn run<I: Input>(
        &mut self,
        program: &Program,
        input: &I,
        sticky: bool,
        env: Env,
        slice: &mut Slice,
    ) -> Outcome {
        loop {
            if !self.attempting {
                if self.at > input.len() {
                    return Outcome::NoMatch;
                }
                if !sticky && let Some(first) = &program.first {
                    match candidate(program, first, input, self.at) {
                        Some(at) => self.at = at,
                        None => return Outcome::NoMatch,
                    }
                }
                let start = if program.unicode {
                    character_start(input, self.at)
                } else {
                    self.at
                };
                self.vm.reset(program, start);
                self.attempting = true;
            }
            match self.vm.run(program, input, env, slice) {
                Run::Matched(end) => return Outcome::Match(self.at, end),
                Run::Paused => return Outcome::Paused,
                Run::Overflow => return Outcome::Overflow,
                Run::Failed if sticky => return Outcome::NoMatch,
                Run::Failed => {
                    self.attempting = false;
                    self.at = advance(input, self.at, program.unicode);
                    if slice.is_over(env, 1) {
                        return Outcome::Paused;
                    }
                }
            }
        }
    }
}

impl Searcher {
    /// Every match: after an empty match the next search starts one character on.
    fn run_all<'a, I: Input>(
        &mut self,
        program: &Program,
        input: &I,
        sticky: bool,
        env: Env<'a>,
        slice: &mut Slice,
        found: &mut Vec<Term<'a>>,
    ) -> Outcome {
        loop {
            match self.run(program, input, sticky, env, slice) {
                Outcome::Match(index, end) => {
                    found.push(match_term(env, index, end, &self.vm.captures));
                    let next = if end <= index {
                        advance(input, end, program.unicode)
                    } else {
                        end
                    };
                    if next > input.len() {
                        return Outcome::NoMatch;
                    }
                    self.at = next;
                    self.attempting = false;
                    if slice.is_over(env, 1) {
                        return Outcome::Paused;
                    }
                }
                other => return other,
            }
        }
    }
}

/// The first index from `at` where the character can start a match.
fn candidate<I: Input>(
    program: &Program,
    first: &CharSet,
    input: &I,
    mut at: usize,
) -> Option<usize> {
    let surrogates = program.unicode && first.has_astral();
    while at < input.len() {
        let char = if program.unicode {
            read(input, character_start(input, at), false, true).map_or(0, |(char, _)| char)
        } else {
            input.unit(at)
        };
        if first.contains(char) || (surrogates && is_high(char)) {
            return Some(at);
        }
        at = advance(input, at, program.unicode);
    }
    None
}
