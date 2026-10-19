//! A small Erlang syntax tree and a printer that produces readable source `erlc` accepts.

use std::fmt::Write as _;

/// An Erlang expression. Patterns use the same type.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Var(String),
    Atom(String),
    Integer(i64),
    Float(f64),
    /// A UTF-8 binary literal.
    Binary(String),
    /// A binary literal of raw bytes, such as a WebAssembly module.
    Bytes(Vec<u8>),
    /// A JavaScript string of the reference engine, as UTF-16 code units. It prints as a
    /// one-byte binary when every unit is at most 0xFF, else as `{'$u16', Binary}` with two
    /// bytes per unit (contract, "Reference semantics").
    JsString(Vec<u16>),
    Tuple(Vec<Expr>),
    List(Vec<Expr>),
    /// `[A, B | Tail]`
    Cons(Vec<Expr>, Box<Expr>),
    Map(Vec<(Expr, Expr)>),
    /// `#{K := V}`: a map pattern that matches a map holding each key.
    MapPattern(Vec<(Expr, Expr)>),
    /// A call to a named function, local (`module` is `None`) or remote.
    Call {
        module: Option<String>,
        function: String,
        args: Vec<Expr>,
    },
    /// A call of a fun held in a variable or produced by an expression.
    Apply(Box<Expr>, Vec<Expr>),
    Match(Box<Expr>, Box<Expr>),
    Case(Box<Expr>, Vec<Clause>),
    Fun {
        name: Option<String>,
        clauses: Vec<Clause>,
    },
    FunRef {
        module: Option<String>,
        function: String,
        arity: usize,
    },
    Block(Vec<Expr>),
    Try {
        body: Vec<Expr>,
        catches: Vec<CatchClause>,
        after: Vec<Expr>,
    },
    Op(&'static str, Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
    /// An expression whose code runs at `Site` of the JavaScript source: the printer
    /// records the line where it starts in the table of `'$frames'/0`.
    Site(Site, Box<Expr>),
}

/// A place of the JavaScript source: a byte offset of the source text, and the index of
/// the function around it in `Frames::functions`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Site {
    pub offset: u32,
    pub function: u32,
}

/// What the stack traces of the reference engine need to know about the code of a module:
/// its source text and its functions. The printer adds `'$frames'/0`, which returns
/// `{Script, Lines, Functions}`: `Script` is the name of the script or `none`, `Lines` holds a record of four 24-bit integers for each line of
/// the Erlang code where a place starts, in order (the line, then the line and the
/// UTF-16 column of the place, both from 1, then the index of its function), and
/// `Functions` holds `{Name, Start, Kind, Class}` for each function, where `Start` is the
/// offset where the function starts.
#[derive(Debug, Clone, PartialEq)]
pub struct Frames {
    /// The name of the script in stack traces, when the compiler knows it, such as
    /// `node:internal/util` for a built-in module of Node.
    pub script: Option<String>,
    pub source: String,
    /// The columns of the first line before the code: the wrapper of a `CommonJS` module.
    pub shift: u32,
    pub functions: Vec<FunctionSite>,
}

/// A function of the source: its name for stack traces, where it starts, its kind
/// (`function`, `method`, `get`, `set`, `constructor`, `wrapper`, or `top`), and the
/// class or object that holds a method (`Object` for an object literal).
#[derive(Debug, Clone, PartialEq)]
pub struct FunctionSite {
    pub name: String,
    pub start: u32,
    pub kind: &'static str,
    pub holder: Option<String>,
}

/// `Patterns when Guards -> Body`. Guard alternatives are joined with `;`.
#[derive(Debug, Clone, PartialEq)]
pub struct Clause {
    pub patterns: Vec<Expr>,
    pub guards: Vec<Expr>,
    pub body: Vec<Expr>,
}

/// `Class:Reason:Stack -> Body` in a `try`. `class` is an atom or a variable.
#[derive(Debug, Clone, PartialEq)]
pub struct CatchClause {
    pub class: Expr,
    pub reason: Expr,
    pub stack: String,
    pub body: Vec<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Function {
    pub name: String,
    pub clauses: Vec<Clause>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Module {
    pub name: String,
    pub functions: Vec<Function>,
    pub frames: Option<Frames>,
}

impl Expr {
    pub fn var(name: impl Into<String>) -> Self {
        Self::Var(name.into())
    }

    pub fn atom(name: impl Into<String>) -> Self {
        Self::Atom(name.into())
    }

    pub fn binary(text: impl Into<String>) -> Self {
        Self::Binary(text.into())
    }

    /// A JavaScript string of the reference engine.
    pub fn js_string(text: &str) -> Self {
        Self::JsString(text.encode_utf16().collect())
    }

    pub fn undefined() -> Self {
        Self::atom("undefined")
    }

    pub fn ok() -> Self {
        Self::atom("ok")
    }

    pub fn call(module: &str, function: &str, args: Vec<Expr>) -> Self {
        Self::Call {
            module: Some(module.to_owned()),
            function: function.to_owned(),
            args,
        }
    }

    pub fn local_call(function: &str, args: Vec<Expr>) -> Self {
        Self::Call {
            module: None,
            function: function.to_owned(),
            args,
        }
    }

    /// A call into `buoy_rt`, the value core every generated module uses.
    pub fn rt(function: &str, args: Vec<Expr>) -> Self {
        Self::call("buoy_rt", function, args)
    }

    pub fn matches(pattern: Expr, value: Expr) -> Self {
        Self::Match(Box::new(pattern), Box::new(value))
    }

    pub fn case(subject: Expr, clauses: Vec<Clause>) -> Self {
        Self::Case(Box::new(subject), clauses)
    }

    pub fn not(value: Expr) -> Self {
        Self::Not(Box::new(value))
    }

    pub fn op(operator: &'static str, left: Expr, right: Expr) -> Self {
        Self::Op(operator, Box::new(left), Box::new(right))
    }

    pub fn tagged(tag: &str, value: Expr) -> Self {
        Self::Tuple(vec![Self::atom(tag), value])
    }

    /// Whether this pattern binds the variable `name`.
    pub fn binds(&self, name: &str) -> bool {
        match self {
            Self::Var(var) => var == name,
            Self::Tuple(items) | Self::List(items) => items.iter().any(|item| item.binds(name)),
            Self::Cons(heads, tail) => {
                heads.iter().any(|item| item.binds(name)) || tail.binds(name)
            }
            _ => false,
        }
    }

    /// A value that has no side effects and costs nothing to repeat.
    pub fn is_trivial(&self) -> bool {
        match self {
            Self::Var(_)
            | Self::Atom(_)
            | Self::Integer(_)
            | Self::Float(_)
            | Self::Binary(_)
            | Self::Bytes(_)
            | Self::JsString(_)
            | Self::FunRef { .. } => true,
            Self::Tuple(items) | Self::List(items) => items.iter().all(Self::is_trivial),
            _ => false,
        }
    }
}

impl Clause {
    pub fn new(pattern: Expr, body: Vec<Expr>) -> Self {
        Self {
            patterns: vec![pattern],
            guards: Vec::new(),
            body,
        }
    }

    pub fn guarded(pattern: Expr, guards: Vec<Expr>, body: Vec<Expr>) -> Self {
        Self {
            patterns: vec![pattern],
            guards,
            body,
        }
    }
}

/// Prints `module` as Erlang source.
pub fn print_module(module: &Module) -> String {
    let mut printer = Printer::default();
    let _ = writeln!(printer.out, "-module({}).", atom(&module.name));
    let mut exports: Vec<String> = module
        .functions
        .iter()
        .map(|function| {
            let arity = function
                .clauses
                .first()
                .map_or(0, |clause| clause.patterns.len());
            format!("{}/{arity}", atom(&function.name))
        })
        .collect();
    if module.frames.is_some() {
        exports.push("'$frames'/0".to_owned());
    }
    let _ = writeln!(printer.out, "-export([{}]).", exports.join(", "));
    printer
        .out
        .push_str("-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function]).\n");
    for function in &module.functions {
        printer.out.push('\n');
        printer.function(function);
    }
    if let Some(frames) = &module.frames {
        printer.frames(frames);
    }
    printer.out
}

const INDENT: &str = "    ";
const INLINE_LIMIT: usize = 72;
const WRAP_LIMIT: usize = 80;

#[derive(Default)]
struct Printer {
    out: String,
    indent: usize,
    /// Set inside `inline`: subexpressions print in place, and printing stops once the text
    /// cannot be one short line. A nested `inline` per level would print the deepest
    /// subtree once for each level above it, which is exponential in the depth of the
    /// continuations that `await` makes.
    one_line: bool,
    /// The lines of `out` before byte `counted`.
    lines: u32,
    counted: usize,
    /// The line where each place starts, in order of the lines.
    sites: Vec<(u32, Site)>,
    /// The place before a fun, which the code after the fun is at again.
    resume: Option<Site>,
}

/// The place of code that is no JavaScript function, such as `'__init__'/0`: a frame there
/// is no frame of a stack trace.
const NO_SITE: Site = Site {
    offset: u32::MAX,
    function: u32::MAX,
};

impl Printer {
    /// The line of the next character of `out`, from 1.
    fn line(&mut self) -> u32 {
        let new = self.out.as_bytes()[self.counted..]
            .iter()
            .filter(|byte| **byte == b'\n')
            .count();
        self.lines += u32::try_from(new).unwrap_or(u32::MAX);
        self.counted = self.out.len();
        self.lines + 1
    }

    /// Records that the code from the current line on is at `site`. Two places start on
    /// two lines, so a frame of the Erlang stack names one place.
    fn site(&mut self, site: Site) {
        self.resume = None;
        let mut line = self.line();
        if let Some(&(last, previous)) = self.sites.last()
            && last == line
        {
            if previous == site {
                return;
            }
            self.newline();
            line = self.line();
        }
        self.sites.push((line, site));
    }

    /// The code after a fun is at the place before the fun again, from the next line on,
    /// unless a place of its own comes first.
    fn resume_after(&mut self, before: Option<Site>) {
        let after = self.sites.last().map(|&(_, site)| site);
        if let Some(before) = before
            && after != Some(before)
        {
            self.resume = Some(before);
        }
    }

    /// `'$frames'/0` of `frames`.
    fn frames(&mut self, frames: &Frames) {
        let places = positions(&frames.source, frames.shift, &self.sites);
        let mut lines = Vec::with_capacity(self.sites.len() * 12);
        for (line, site) in &self.sites {
            let (js_line, column) = places
                .get(&site.offset)
                .copied()
                .unwrap_or((0, 0));
            for value in [*line, js_line, column, site.function] {
                lines.extend_from_slice(&value.min(0x00FF_FFFF).to_be_bytes()[1..]);
            }
        }
        let functions: Vec<String> = frames
            .functions
            .iter()
            .map(|function| {
                format!(
                    "{{{}, {}, {}, {}}}",
                    binary(&function.name),
                    function.start,
                    atom(function.kind),
                    function
                        .holder
                        .as_deref()
                        .map_or_else(|| "undefined".to_owned(), binary)
                )
            })
            .collect();
        let script = frames
            .script
            .as_deref()
            .map_or_else(|| "none".to_owned(), binary);
        let _ = write!(
            self.out,
            "\n'$frames'() ->\n    {{{script},\n     {},\n     {{{}}}}}.\n",
            raw_binary(&lines),
            functions.join(",\n      ")
        );
        // The code passes the result of each JavaScript call through `'$r'/1`, so the call
        // is no tail call and its caller stays on the stack (`reference::sites`).
        self.out.push_str("\n'$r'(Value) -> Value.\n");
    }

    fn function(&mut self, function: &Function) {
        let name = atom(&function.name);
        // A function of the module that is no JavaScript function has no place, until
        // the place of the function that it holds.
        self.resume = None;
        let line = self.line();
        self.sites.push((line, NO_SITE));
        for (index, clause) in function.clauses.iter().enumerate() {
            if index > 0 {
                self.out.push_str(";\n");
            }
            self.out.push_str(&name);
            self.clause_head(clause);
            self.clause_body(&clause.body);
        }
        self.out.push_str(".\n");
    }

    fn clause_head(&mut self, clause: &Clause) {
        self.out.push('(');
        self.comma_separated(&clause.patterns);
        self.out.push(')');
        self.guards(&clause.guards);
        self.out.push_str(" ->");
    }

    fn guards(&mut self, guards: &[Expr]) {
        if guards.is_empty() {
            return;
        }
        self.out.push_str(" when ");
        for (index, guard) in guards.iter().enumerate() {
            if index > 0 {
                self.out.push_str("; ");
            }
            self.expr(guard);
        }
    }

    /// Prints a clause body after `->`: inline when it is one short expression.
    fn clause_body(&mut self, body: &[Expr]) {
        if let [only] = body
            && self.print_inline(only)
        {
            return;
        }
        self.indent += 1;
        self.body(body);
        self.indent -= 1;
    }

    fn body(&mut self, body: &[Expr]) {
        for (index, expr) in body.iter().enumerate() {
            if index > 0 {
                self.out.push(',');
            }
            self.newline();
            self.expr(expr);
        }
    }

    fn newline(&mut self) {
        self.out.push('\n');
        if let Some(site) = self.resume.take() {
            let line = self.line();
            self.sites.push((line, site));
        }
        for _ in 0..self.indent {
            self.out.push_str(INDENT);
        }
    }

    fn comma_separated(&mut self, items: &[Expr]) {
        for (index, item) in items.iter().enumerate() {
            if index > 0 {
                self.out.push_str(", ");
            }
            self.expr(item);
        }
    }

    fn expr(&mut self, expr: &Expr) {
        if self.one_line && self.overflows() {
            return;
        }
        match expr {
            Expr::Var(name) => self.out.push_str(&shorten(name, NAME_LIMIT)),
            Expr::Atom(name) => self.out.push_str(&atom(name)),
            Expr::Integer(value) => {
                let _ = write!(self.out, "{value}");
            }
            Expr::Float(value) => self.out.push_str(&float(*value)),
            Expr::Binary(text) => self.out.push_str(&binary(text)),
            Expr::Bytes(bytes) => self.out.push_str(&raw_binary(bytes)),
            Expr::JsString(units) => self.out.push_str(&js_string(units)),
            Expr::Tuple(items) => self.elements("{", items, "}"),
            Expr::List(items) => self.elements("[", items, "]"),
            Expr::Cons(heads, tail) => {
                self.out.push('[');
                self.comma_separated(heads);
                self.out.push_str(" | ");
                self.expr(tail);
                self.out.push(']');
            }
            Expr::Map(entries) => self.map(entries, "=>"),
            Expr::MapPattern(entries) => self.map(entries, ":="),
            Expr::Call {
                module,
                function,
                args,
            } => {
                if let Some(module) = module {
                    self.out.push_str(&atom(module));
                    self.out.push(':');
                }
                self.out.push_str(&atom(function));
                self.elements("(", args, ")");
            }
            Expr::Apply(fun, args) => {
                self.operand(fun);
                self.elements("(", args, ")");
            }
            Expr::Match(pattern, value) => {
                self.expr(pattern);
                self.out.push_str(" = ");
                self.expr(value);
            }
            Expr::Case(subject, clauses) => self.case(subject, clauses),
            Expr::Fun { name, clauses } => self.fun(name.as_deref(), clauses),
            Expr::FunRef {
                module,
                function,
                arity,
            } => {
                self.out.push_str("fun ");
                if let Some(module) = module {
                    self.out.push_str(&atom(module));
                    self.out.push(':');
                }
                let _ = write!(self.out, "{}/{arity}", atom(function));
            }
            Expr::Block(body) => {
                self.out.push_str("begin");
                self.indent += 1;
                self.body(body);
                self.indent -= 1;
                self.newline();
                self.out.push_str("end");
            }
            Expr::Try {
                body,
                catches,
                after,
            } => self.try_expr(body, catches, after),
            Expr::Op(operator, left, right) => {
                self.operand(left);
                let _ = write!(self.out, " {operator} ");
                self.operand(right);
            }
            Expr::Not(value) => {
                self.out.push_str("not ");
                self.operand(value);
            }
            Expr::Site(site, value) => {
                // A place needs a line of its own, which no inline form gives.
                if self.one_line {
                    self.out.push('\n');
                    return;
                }
                self.site(*site);
                self.expr(value);
            }
        }
    }

    /// Prints an operand of an operator, in parentheses when it is itself an operation.
    fn operand(&mut self, expr: &Expr) {
        if matches!(
            expr,
            Expr::Op(..) | Expr::Not(_) | Expr::Match(..) | Expr::Fun { .. }
        ) {
            self.out.push('(');
            self.expr(expr);
            self.out.push(')');
        } else {
            self.expr(expr);
        }
    }

    fn map(&mut self, entries: &[(Expr, Expr)], operator: &'static str) {
        let pairs: Vec<Expr> = entries
            .iter()
            .map(|(key, value)| Expr::Op(operator, Box::new(key.clone()), Box::new(value.clone())))
            .collect();
        self.elements("#{", &pairs, "}");
    }

    /// Prints `items` between `open` and `close`: on one line when it is short, else one
    /// item per line. A multi-line last item, such as a fun, may stay on the line.
    fn elements(&mut self, open: &str, items: &[Expr], close: &str) {
        let width = if self.one_line {
            Some(0)
        } else {
            items
                .iter()
                .enumerate()
                .try_fold(0, |width, (index, item)| match inline(item) {
                    Some(text) => Some(width + text.len() + 2),
                    None if index + 1 == items.len() => Some(width),
                    None => None,
                })
        };
        self.out.push_str(open);
        if items.len() < 2 || width.is_some_and(|width| width <= WRAP_LIMIT) {
            self.comma_separated(items);
        } else {
            self.indent += 1;
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    self.out.push(',');
                }
                self.newline();
                self.expr(item);
            }
            self.indent -= 1;
            self.newline();
        }
        self.out.push_str(close);
    }

    fn case(&mut self, subject: &Expr, clauses: &[Clause]) {
        self.out.push_str("case ");
        self.expr(subject);
        self.out.push_str(" of");
        self.indent += 1;
        for (index, clause) in clauses.iter().enumerate() {
            if index > 0 {
                self.out.push(';');
            }
            self.newline();
            self.comma_separated(&clause.patterns);
            self.guards(&clause.guards);
            self.out.push_str(" ->");
            self.clause_body(&clause.body);
        }
        self.indent -= 1;
        self.newline();
        self.out.push_str("end");
    }

    /// A single-clause fun keeps its head on the current line. A fun with several clauses
    /// puts each clause on its own line.
    fn fun(&mut self, name: Option<&str>, clauses: &[Clause]) {
        let before = self.sites.last().map(|&(_, site)| site);
        self.fun_clauses(name, clauses);
        if !self.one_line {
            self.resume_after(before);
        }
    }

    fn fun_clauses(&mut self, name: Option<&str>, clauses: &[Clause]) {
        self.out.push_str("fun");
        if let [clause] = clauses {
            if let Some(name) = name {
                self.out.push(' ');
                self.out.push_str(name);
            }
            self.clause_head(clause);
            if let [only] = clause.body.as_slice()
                && self.print_inline(only)
            {
                self.out.push_str(" end");
                return;
            }
            self.clause_body(&clause.body);
        } else {
            self.indent += 1;
            for (index, clause) in clauses.iter().enumerate() {
                if index > 0 {
                    self.out.push(';');
                }
                self.newline();
                self.out.push_str(name.unwrap_or(""));
                self.clause_head(clause);
                self.clause_body(&clause.body);
            }
            self.indent -= 1;
        }
        self.newline();
        self.out.push_str("end");
    }

    fn try_expr(&mut self, body: &[Expr], catches: &[CatchClause], after: &[Expr]) {
        self.out.push_str("try");
        self.indent += 1;
        self.body(body);
        self.indent -= 1;
        if !catches.is_empty() {
            self.newline();
            self.out.push_str("catch");
            self.indent += 1;
            for (index, clause) in catches.iter().enumerate() {
                if index > 0 {
                    self.out.push(';');
                }
                self.newline();
                self.expr(&clause.class);
                self.out.push(':');
                self.expr(&clause.reason);
                let _ = write!(self.out, ":{} ->", clause.stack);
                self.clause_body(&clause.body);
            }
            self.indent -= 1;
        }
        if !after.is_empty() {
            self.newline();
            self.out.push_str("after");
            self.indent += 1;
            self.body(after);
            self.indent -= 1;
        }
        self.newline();
        self.out.push_str("end");
    }

    /// Prints a space and `expr` when `expr` has a short one-line form, and says whether it
    /// did. Inside `inline` it always prints, and `inline` checks the whole line.
    fn print_inline(&mut self, expr: &Expr) -> bool {
        if self.one_line {
            self.out.push(' ');
            self.expr(expr);
            return true;
        }
        let Some(text) = inline(expr) else {
            return false;
        };
        self.out.push(' ');
        self.out.push_str(&text);
        true
    }

    fn overflows(&self) -> bool {
        self.out.len() > INLINE_LIMIT || self.out.contains('\n')
    }
}

/// The one-line form of `expr`, when it has one and it is short.
fn inline(expr: &Expr) -> Option<String> {
    let mut printer = Printer {
        one_line: true,
        ..Printer::default()
    };
    printer.expr(expr);
    (!printer.overflows()).then_some(printer.out)
}

/// The line and the UTF-16 column, both from 1, of the offset of each place in `source`,
/// as V8 counts them: `\n`, `\r`, `\r\n`, U+2028, and U+2029 end a line. `shift` columns of
/// the first line come before the code.
fn positions(
    source: &str,
    shift: u32,
    sites: &[(u32, Site)],
) -> std::collections::HashMap<u32, (u32, u32)> {
    let mut offsets: Vec<u32> = sites.iter().map(|(_, site)| site.offset).collect();
    offsets.sort_unstable();
    offsets.dedup();
    let mut places = std::collections::HashMap::with_capacity(offsets.len());
    let mut wanted = offsets.into_iter().peekable();
    let (mut line, mut column) = (1_u32, 0_u32);
    let mut chars = source.char_indices().peekable();
    loop {
        let at = chars.peek().map_or(source.len(), |&(index, _)| index);
        while let Some(&offset) = wanted.peek()
            && offset as usize <= at
        {
            let column = if line == 1 { column.saturating_sub(shift) } else { column };
            places.insert(offset, (line, column + 1));
            wanted.next();
        }
        let Some((_, c)) = chars.next() else {
            break;
        };
        match c {
            '\r' if chars.peek().is_some_and(|&(_, next)| next == '\n') => {
                column += 1;
            }
            '\n' | '\r' | '\u{2028}' | '\u{2029}' => {
                line += 1;
                column = 0;
            }
            _ => column += u32::try_from(c.len_utf16()).unwrap_or(1),
        }
    }
    places
}

const RESERVED: &[&str] = &[
    "after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case",
    "catch", "cond", "div", "else", "end", "fun", "if", "let", "maybe", "not", "of", "or",
    "orelse", "receive", "rem", "try", "when", "xor",
];

/// The longest atom and variable name that Buoy writes, in characters. Erlang accepts 255,
/// but its compiler names a fun after its function, as `-Name/0-fun-0-`, in an atom of
/// its own, so a name leaves room for that suffix.
const NAME_LIMIT: usize = 230;

/// `name`, or when it has more than `limit` characters, a prefix of it and a hash of the
/// whole name, so that two long names stay apart.
pub fn shorten(name: &str, limit: usize) -> String {
    if name.chars().count() <= limit {
        return name.to_owned();
    }
    let hash = fnv1a(name);
    let prefix: String = name.chars().take(limit - 17).collect();
    format!("{prefix}_{hash:016x}")
}

/// The 64-bit FNV-1a hash of `text`.
pub fn fnv1a(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// An atom in source form, quoted when it needs quotes.
pub fn atom(name: &str) -> String {
    let name = shorten(name, NAME_LIMIT);
    let name = name.as_str();
    let mut chars = name.chars();
    let plain = chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '@')
        && !RESERVED.contains(&name);
    if plain {
        return name.to_owned();
    }
    let mut quoted = String::with_capacity(name.len() + 2);
    quoted.push('\'');
    for c in name.chars() {
        escape_char(&mut quoted, c, '\'');
    }
    quoted.push('\'');
    quoted
}

/// `<<"...">>` of raw bytes: a string literal reads each character as one byte, so the
/// printable ASCII stays and every other byte is a three-digit octal escape.
fn raw_binary(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2 + 6);
    out.push_str("<<\"");
    for &byte in bytes {
        match byte {
            b'"' | b'\\' => {
                out.push('\\');
                out.push(char::from(byte));
            }
            b' '..=b'~' => out.push(char::from(byte)),
            _ => {
                let _ = write!(out, "\\{byte:03o}");
            }
        }
    }
    out.push_str("\">>");
    out
}

fn binary(text: &str) -> String {
    if text.is_empty() {
        return "<<>>".to_owned();
    }
    // erl_scan rejects U+FFFE and U+FFFF in a string, even as an escape, so each one is an
    // integer segment of its own.
    if text.contains(['\u{FFFE}', '\u{FFFF}']) {
        let mut segments = Vec::new();
        let mut part = String::new();
        for c in text.chars() {
            if matches!(c, '\u{FFFE}' | '\u{FFFF}') {
                if !part.is_empty() {
                    segments.push(segment(&std::mem::take(&mut part)));
                }
                segments.push(format!("{}/utf8", u32::from(c)));
            } else {
                part.push(c);
            }
        }
        if !part.is_empty() {
            segments.push(segment(&part));
        }
        return format!("<<{}>>", segments.join(", "));
    }
    let mut out = String::with_capacity(text.len() + 6);
    out.push_str("<<\"");
    for c in text.chars() {
        escape_char(&mut out, c, '"');
    }
    out.push('"');
    if !text.is_ascii() {
        out.push_str("/utf8");
    }
    out.push_str(">>");
    out
}

/// A string segment of a binary: `"text"/utf8`.
fn segment(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        escape_char(&mut out, c, '"');
    }
    out.push_str("\"/utf8");
    out
}

fn js_string(units: &[u16]) -> String {
    if units.iter().any(|unit| *unit > 0xFF) {
        let units: Vec<String> = units.iter().map(|unit| format!("{unit}:16")).collect();
        return format!("{{'$u16', <<{}>>}}", units.join(","));
    }
    if units.is_empty() {
        return "<<>>".to_owned();
    }
    let mut out = String::from("<<\"");
    for unit in units {
        match char::from_u32(u32::from(*unit)) {
            Some(c) if c.is_ascii() => escape_char(&mut out, c, '"'),
            _ => {
                let _ = write!(out, "\\x{{{unit:X}}}");
            }
        }
    }
    out.push_str("\">>");
    out
}

fn escape_char(out: &mut String, c: char, quote: char) {
    match c {
        '\\' => out.push_str("\\\\"),
        '\n' => out.push_str("\\n"),
        '\r' => out.push_str("\\r"),
        '\t' => out.push_str("\\t"),
        c if c == quote => {
            out.push('\\');
            out.push(c);
        }
        // erl_scan rejects U+FFFE and U+FFFF in source text, so they are escapes too.
        c if c.is_control()
            || (c.is_whitespace() && c != ' ')
            || matches!(c, '\u{FFFE}' | '\u{FFFF}') =>
        {
            let _ = write!(out, "\\x{{{:X}}}", u32::from(c));
        }
        c => out.push(c),
    }
}

/// A float in a form Erlang reads back to the same double.
fn float(value: f64) -> String {
    let text = format!("{value:?}");
    match text.find('e') {
        Some(exponent) if !text[..exponent].contains('.') => {
            format!("{}.0{}", &text[..exponent], &text[exponent..])
        }
        Some(_) => text,
        None if text.contains('.') => text,
        None => format!("{text}.0"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_atoms_only_when_needed() {
        assert_eq!(atom("buoy_rt"), "buoy_rt");
        assert_eq!(atom("Counter#new"), "'Counter#new'");
        assert_eq!(atom("__init__"), "'__init__'");
        assert_eq!(atom("end"), "'end'");
        assert_eq!(atom("it's"), "'it\\'s'");
    }

    #[test]
    fn shortens_names_erlang_cannot_hold() {
        let long = "f".repeat(300);
        let other = format!("{}g", "f".repeat(299));
        assert_eq!(atom(&long).chars().count(), NAME_LIMIT);
        assert_ne!(atom(&long), atom(&other));
        assert_eq!(shorten("short", 10), "short");
    }

    #[test]
    fn prints_floats_erlang_can_read() {
        assert_eq!(float(1.5), "1.5");
        assert_eq!(float(1e21), "1.0e21");
        assert_eq!(float(1e-7), "1.0e-7");
        assert_eq!(float(2.5e-8), "2.5e-8");
        assert_eq!(float(-0.0), "-0.0");
    }

    #[test]
    fn prints_js_strings_as_one_or_two_bytes_per_unit() {
        let units = |text: &str| text.encode_utf16().collect::<Vec<u16>>();
        assert_eq!(js_string(&units("a\"b")), "<<\"a\\\"b\">>");
        assert_eq!(js_string(&units("café")), "<<\"caf\\x{E9}\">>");
        assert_eq!(js_string(&units("€")), "{'$u16', <<8364:16>>}");
        assert_eq!(js_string(&[0xD800, 0x61]), "{'$u16', <<55296:16,97:16>>}");
        assert_eq!(js_string(&[]), "<<>>");
    }

    #[test]
    fn prints_deeply_nested_funs_once() {
        let fun = |body: Expr| Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![Expr::Var("V".to_owned())],
                guards: Vec::new(),
                body: vec![body],
            }],
        };
        let short = fun(Expr::Atom("ok".to_owned()));
        assert_eq!(inline(&short).as_deref(), Some("fun(V) -> ok end"));
        // 200 levels, as 200 awaits in a row nest their continuations: before the fix, this
        // printed the innermost fun 2^200 times.
        let deep = (0..200).fold(Expr::Atom("ok".to_owned()), |body, _| fun(body));
        let mut printer = Printer::default();
        printer.expr(&deep);
        assert_eq!(printer.out.matches("fun(V) ->").count(), 200);
        assert!(
            printer
                .out
                .contains("fun(V) -> fun(V) -> fun(V) -> fun(V) -> ok end end end end")
        );
    }

    #[test]
    fn escapes_the_noncharacters_that_erl_scan_rejects() {
        assert_eq!(
            binary("a\u{FFFF}b"),
            "<<\"a\"/utf8, 65535/utf8, \"b\"/utf8>>"
        );
    }

    #[test]
    fn marks_non_ascii_binaries_as_utf8() {
        assert_eq!(binary("a\"b\n"), "<<\"a\\\"b\\n\">>");
        assert_eq!(binary("café"), "<<\"café\"/utf8>>");
    }
}
