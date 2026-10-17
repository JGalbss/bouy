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
    /// A JavaScript string of the reference engine, as UTF-16 code units. It prints as a
    /// one-byte binary when every unit is at most 0xFF, else as `{'$u16', Binary}` with two
    /// bytes per unit (contract, "Reference semantics").
    JsString(Vec<u16>),
    Tuple(Vec<Expr>),
    List(Vec<Expr>),
    /// `[A, B | Tail]`
    Cons(Vec<Expr>, Box<Expr>),
    Map(Vec<(Expr, Expr)>),
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

    /// A call into `bouy_rt`, the value core every generated module uses.
    pub fn rt(function: &str, args: Vec<Expr>) -> Self {
        Self::call("bouy_rt", function, args)
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
    let exports: Vec<String> = module
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
    let _ = writeln!(printer.out, "-export([{}]).", exports.join(", "));
    printer
        .out
        .push_str("-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function]).\n");
    for function in &module.functions {
        printer.out.push('\n');
        printer.function(function);
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
}

impl Printer {
    fn function(&mut self, function: &Function) {
        let name = atom(&function.name);
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
            && let Some(text) = inline(only)
        {
            self.out.push(' ');
            self.out.push_str(&text);
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
        match expr {
            Expr::Var(name) => self.out.push_str(&shorten(name, NAME_LIMIT)),
            Expr::Atom(name) => self.out.push_str(&atom(name)),
            Expr::Integer(value) => {
                let _ = write!(self.out, "{value}");
            }
            Expr::Float(value) => self.out.push_str(&float(*value)),
            Expr::Binary(text) => self.out.push_str(&binary(text)),
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
            Expr::Map(entries) => self.map(entries),
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

    fn map(&mut self, entries: &[(Expr, Expr)]) {
        let pairs: Vec<Expr> = entries
            .iter()
            .map(|(key, value)| Expr::Op("=>", Box::new(key.clone()), Box::new(value.clone())))
            .collect();
        self.elements("#{", &pairs, "}");
    }

    /// Prints `items` between `open` and `close`: on one line when it is short, else one
    /// item per line. A multi-line last item, such as a fun, may stay on the line.
    fn elements(&mut self, open: &str, items: &[Expr], close: &str) {
        let width = items
            .iter()
            .enumerate()
            .try_fold(0, |width, (index, item)| match inline(item) {
                Some(text) => Some(width + text.len() + 2),
                None if index + 1 == items.len() => Some(width),
                None => None,
            });
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
        self.out.push_str("fun");
        if let [clause] = clauses {
            if let Some(name) = name {
                self.out.push(' ');
                self.out.push_str(name);
            }
            self.clause_head(clause);
            if let [only] = clause.body.as_slice()
                && let Some(text) = inline(only)
            {
                self.out.push(' ');
                self.out.push_str(&text);
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
}

/// The one-line form of `expr`, when it has one and it is short.
fn inline(expr: &Expr) -> Option<String> {
    let mut printer = Printer::default();
    printer.expr(expr);
    (!printer.out.contains('\n') && printer.out.len() <= INLINE_LIMIT).then_some(printer.out)
}

const RESERVED: &[&str] = &[
    "after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case",
    "catch", "cond", "div", "else", "end", "fun", "if", "let", "maybe", "not", "of", "or",
    "orelse", "receive", "rem", "try", "when", "xor",
];

/// The longest atom and variable name Erlang accepts, in characters.
const NAME_LIMIT: usize = 255;

/// `name`, or when it has more than `limit` characters, a prefix of it and a hash of the
/// whole name, so that two long names stay apart.
pub fn shorten(name: &str, limit: usize) -> String {
    if name.chars().count() <= limit {
        return name.to_owned();
    }
    let hash = name.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    let prefix: String = name.chars().take(limit - 17).collect();
    format!("{prefix}_{hash:016x}")
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

fn binary(text: &str) -> String {
    if text.is_empty() {
        return "<<>>".to_owned();
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
        c if c.is_control() || (c.is_whitespace() && c != ' ') => {
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
        assert_eq!(atom("bouy_rt"), "bouy_rt");
        assert_eq!(atom("Counter#new"), "'Counter#new'");
        assert_eq!(atom("__init__"), "'__init__'");
        assert_eq!(atom("end"), "'end'");
        assert_eq!(atom("it's"), "'it\\'s'");
    }

    #[test]
    fn shortens_names_erlang_cannot_hold() {
        let long = "f".repeat(300);
        let other = format!("{}g", "f".repeat(299));
        assert_eq!(atom(&long).chars().count(), 255);
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
    fn marks_non_ascii_binaries_as_utf8() {
        assert_eq!(binary("a\"b\n"), "<<\"a\\\"b\\n\">>");
        assert_eq!(binary("café"), "<<\"café\"/utf8>>");
    }
}
