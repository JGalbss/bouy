//! The programs of the campaign: one `console.log(<expression>);` statement per line. Each
//! expression is a tree, so the minimizer can delete statements and simplify expressions.

use std::fmt::Write as _;
use std::iter;

/// A program: the expression that each statement prints, one statement per line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Program(pub Vec<Expr>);

impl Program {
    #[must_use]
    pub fn source(&self) -> String {
        self.0.iter().fold(String::new(), |mut source, expression| {
            let _ = writeln!(source, "console.log({});", expression.render());
            source
        })
    }

    /// Every program one step simpler than this one: one expression replaced with a simpler
    /// expression. The minimizer deletes statements on its own.
    #[must_use]
    pub fn simpler(&self) -> Vec<Self> {
        self.0
            .iter()
            .enumerate()
            .flat_map(|(index, statement)| {
                statement.simpler().into_iter().map(move |simpler| {
                    let mut program = self.clone();
                    program.0[index] = simpler;
                    program
                })
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Expr {
    /// A number literal as source text, such as `1.5`, `-0`, or `1e21`.
    Number(String),
    /// A string literal, as the source text of each character or escape, such as `a`,
    /// `\n`, or `\u00e9`.
    String(Vec<String>),
    /// Any other atom as source text, such as `null`, `NaN`, or `Number.MAX_SAFE_INTEGER`.
    Atom(String),
    /// A string literal whose text is the source of the inner value, as JSON.
    Text(Box<Expr>),
    Array(Vec<Expr>),
    /// The entries of an object literal. Each key is the source of a string literal.
    Object(Vec<(String, Expr)>),
    Unary(&'static str, Box<Expr>),
    Binary(&'static str, Box<Expr>, Box<Expr>),
    /// A call of a global function, such as `Math.floor(x)`.
    Call(&'static str, Vec<Expr>),
    /// A method call, such as `x.toFixed(2)`.
    Method(Box<Expr>, &'static str, Vec<Expr>),
    /// A property read, such as `s.length`.
    Property(Box<Expr>, &'static str),
    /// An element read, such as `s[1]`.
    Index(Box<Expr>, Box<Expr>),
}

impl Expr {
    /// The string literal of `text`, with the escapes that keep it on one line.
    #[must_use]
    pub fn string(text: &str) -> Self {
        Self::String(text.chars().map(escape).collect())
    }

    #[must_use]
    pub fn render(&self) -> String {
        match self {
            Self::Number(text) | Self::Atom(text) => text.clone(),
            Self::String(pieces) => format!("\"{}\"", pieces.concat()),
            Self::Text(value) => format!(
                "\"{}\"",
                value.render().chars().map(escape).collect::<String>()
            ),
            Self::Array(items) => format!("[{}]", list(items)),
            Self::Object(entries) => {
                let entries: Vec<String> = entries
                    .iter()
                    .map(|(key, value)| format!("{key}: {}", value.render()))
                    .collect();
                format!("{{{}}}", entries.join(", "))
            }
            Self::Unary(operator, operand) => format!("{operator}{}", operand.operand()),
            Self::Binary(operator, left, right) => {
                format!("{} {operator} {}", left.operand(), right.operand())
            }
            Self::Call(callee, arguments) => format!("{callee}({})", list(arguments)),
            Self::Method(receiver, name, arguments) => {
                format!("{}.{name}({})", receiver.receiver(), list(arguments))
            }
            Self::Property(receiver, name) => format!("{}.{name}", receiver.receiver()),
            Self::Index(receiver, index) => {
                format!("{}[{}]", receiver.receiver(), index.render())
            }
        }
    }

    /// The source of an operand of an operator. `-1 ** 2` is a syntax error, so a negative
    /// literal gets parentheses, as does every nested operator.
    fn operand(&self) -> String {
        match self {
            Self::Unary(..) | Self::Binary(..) => format!("({})", self.render()),
            Self::Number(text) | Self::Atom(text) if text.starts_with('-') => {
                format!("({text})")
            }
            _ => self.render(),
        }
    }

    /// The source of the object of a member access: `1.toFixed()` is a syntax error.
    fn receiver(&self) -> String {
        match self {
            Self::Number(_) | Self::Object(_) => format!("({})", self.render()),
            _ => self.operand(),
        }
    }

    fn children(&self) -> Vec<&Self> {
        match self {
            Self::Number(_) | Self::String(_) | Self::Atom(_) => Vec::new(),
            Self::Text(inner) | Self::Unary(_, inner) | Self::Property(inner, _) => vec![inner],
            Self::Array(items) | Self::Call(_, items) => items.iter().collect(),
            Self::Object(entries) => entries.iter().map(|(_, value)| value).collect(),
            Self::Binary(_, left, right) | Self::Index(left, right) => vec![left, right],
            Self::Method(receiver, _, arguments) => {
                iter::once(&**receiver).chain(arguments).collect()
            }
        }
    }

    fn children_mut(&mut self) -> Vec<&mut Self> {
        match self {
            Self::Number(_) | Self::String(_) | Self::Atom(_) => Vec::new(),
            Self::Text(inner) | Self::Unary(_, inner) | Self::Property(inner, _) => vec![inner],
            Self::Array(items) | Self::Call(_, items) => items.iter_mut().collect(),
            Self::Object(entries) => entries.iter_mut().map(|(_, value)| value).collect(),
            Self::Binary(_, left, right) | Self::Index(left, right) => vec![left, right],
            Self::Method(receiver, _, arguments) => {
                iter::once(&mut **receiver).chain(arguments).collect()
            }
        }
    }

    /// Every expression one step simpler than this one, the largest steps first: a child in
    /// place of the whole, then a shorter literal or list, then a simpler child. Each step
    /// shrinks the tree or moves a literal toward `0`, so a search over them ends.
    #[must_use]
    pub fn simpler(&self) -> Vec<Self> {
        let children = self.children();
        let mut found: Vec<Self> = children.iter().map(|child| (*child).clone()).collect();
        found.extend(self.shorter());
        for (index, child) in children.into_iter().enumerate() {
            for simpler in child.simpler() {
                let mut copy = self.clone();
                if let Some(slot) = copy.children_mut().into_iter().nth(index) {
                    *slot = simpler;
                }
                found.push(copy);
            }
        }
        found
    }

    /// The literals and lists one step shorter than this one.
    fn shorter(&self) -> Vec<Self> {
        match self {
            Self::Number(text) => ["0", "1"]
                .into_iter()
                .filter(|simple| text != "0" && text != simple)
                .map(|simple| Self::Number(simple.to_owned()))
                .collect(),
            Self::Atom(_) => vec![Self::Number("0".to_owned())],
            Self::String(pieces) => removals(pieces).map(Self::String).collect(),
            Self::Array(items) => removals(items).map(Self::Array).collect(),
            Self::Object(entries) => removals(entries).map(Self::Object).collect(),
            Self::Call(callee, arguments) if !arguments.is_empty() => vec![Self::Call(
                callee,
                arguments[..arguments.len() - 1].to_vec(),
            )],
            Self::Method(receiver, name, arguments) if !arguments.is_empty() => {
                vec![Self::Method(
                    receiver.clone(),
                    name,
                    arguments[..arguments.len() - 1].to_vec(),
                )]
            }
            _ => Vec::new(),
        }
    }
}

fn list(items: &[Expr]) -> String {
    items
        .iter()
        .map(Expr::render)
        .collect::<Vec<_>>()
        .join(", ")
}

/// Each copy of `items` with one item removed.
fn removals<T: Clone>(items: &[T]) -> impl Iterator<Item = Vec<T>> + '_ {
    (0..items.len()).map(|index| {
        let mut copy = items.to_vec();
        copy.remove(index);
        copy
    })
}

/// The source of `character` inside a double-quoted string literal. The escapes keep a
/// statement on one line, so the line of a diagnostic names its statement.
fn escape(character: char) -> String {
    match character {
        '\\' => "\\\\".to_owned(),
        '"' => "\\\"".to_owned(),
        '\n' => "\\n".to_owned(),
        '\r' => "\\r".to_owned(),
        '\t' => "\\t".to_owned(),
        '\u{0}'..='\u{1f}' | '\u{7f}' | '\u{2028}' | '\u{2029}' => {
            format!("\\u{:04x}", u32::from(character))
        }
        _ => character.to_string(),
    }
}

/// The source with each string and number literal replaced by `_`. The campaign keeps one
/// case for each shape of a minimized program.
#[must_use]
pub fn shape(source: &str) -> String {
    let mut shape = String::with_capacity(source.len());
    let mut characters = source.chars().peekable();
    while let Some(character) = characters.next() {
        let after_name = shape
            .chars()
            .next_back()
            .is_some_and(|last| last.is_alphanumeric() || last == '_' || last == '$');
        if character == '"' {
            while let Some(inside) = characters.next() {
                match inside {
                    '\\' => {
                        characters.next();
                    }
                    '"' => break,
                    _ => {}
                }
            }
            shape.push('_');
        } else if character.is_ascii_digit() && !after_name {
            let mut last = character;
            while let Some(&next) = characters.peek() {
                let sign = matches!(next, '+' | '-') && matches!(last, 'e' | 'E');
                if !(next.is_ascii_alphanumeric() || next == '.' || next == '_' || sign) {
                    break;
                }
                last = next;
                characters.next();
            }
            shape.push('_');
        } else {
            shape.push(character);
        }
    }
    shape
}

#[cfg(test)]
mod tests {
    use super::*;

    fn number(text: &str) -> Expr {
        Expr::Number(text.to_owned())
    }

    #[test]
    fn operators_and_receivers_get_the_parentheses_that_javascript_needs() {
        let power = Expr::Binary("**", Box::new(number("-1")), Box::new(number("2")));
        assert_eq!(power.render(), "(-1) ** 2");
        let fixed = Expr::Method(Box::new(number("1")), "toFixed", vec![number("2")]);
        assert_eq!(fixed.render(), "(1).toFixed(2)");
        let negated = Expr::Unary("-", Box::new(Expr::Unary("-", Box::new(number("0")))));
        assert_eq!(negated.render(), "-(-0)");
        let text = Expr::Text(Box::new(Expr::Array(vec![Expr::string("a\"\n")])));
        assert_eq!(text.render(), r#""[\"a\\\"\\n\"]""#);
    }

    #[test]
    fn simpler_expressions_start_with_the_children() {
        let sum = Expr::Binary("+", Box::new(number("7")), Box::new(Expr::string("ab")));
        let simpler: Vec<String> = sum.simpler().iter().map(Expr::render).collect();
        assert_eq!(
            simpler,
            [
                "7",
                "\"ab\"",
                "0 + \"ab\"",
                "1 + \"ab\"",
                "7 + \"b\"",
                "7 + \"a\""
            ]
        );
        assert!(number("0").simpler().is_empty());
        assert_eq!(Expr::Atom("NaN".to_owned()).simpler(), [number("0")]);
        assert_eq!(number("1").simpler(), [number("0")]);
    }

    #[test]
    fn a_shape_hides_the_literals() {
        let source = "console.log((1.5e-7).toFixed(2), Math.log2(\"a\\\"b\"), 0x1f, x1);\n";
        assert_eq!(
            shape(source),
            "console.log((_).toFixed(_), Math.log2(_), _, x1);\n"
        );
    }
}
