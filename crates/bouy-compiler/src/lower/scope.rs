//! Erlang variable names for one Erlang function: SSA versions of each TypeScript variable,
//! keyed by oxc `SymbolId`, and compiler temporaries.

use std::collections::HashMap;

use oxc::semantic::SymbolId;

use crate::erlang::Expr;

/// A variable that lowering versions: a TypeScript symbol, or `this` inside a class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Target {
    This,
    Symbol(SymbolId),
}

/// The names of one Erlang function. Every name is unique within the function, because each
/// base name has its own counter that never resets: `Count@1`, `Count@2`, `T@1`.
#[derive(Debug, Default, Clone)]
pub struct Scope {
    counters: HashMap<String, u32>,
    versions: HashMap<Target, String>,
}

/// The versions in effect at one point, to restore after lowering a branch.
pub type Versions = HashMap<Target, String>;

impl Scope {
    /// A fresh name `Base@N`.
    pub fn fresh(&mut self, base: &str) -> String {
        let counter = self.counters.entry(base.to_owned()).or_insert(0);
        *counter += 1;
        format!("{base}@{counter}")
    }

    pub fn temp(&mut self) -> String {
        self.fresh("T")
    }

    /// Gives `target` a new version named after `base` and returns its name.
    pub fn bind(&mut self, target: Target, base: &str) -> String {
        let name = self.fresh(base);
        self.versions.insert(target, name.clone());
        name
    }

    /// Makes `name` the current version of `target`.
    pub fn set(&mut self, target: Target, name: String) {
        self.versions.insert(target, name);
    }

    pub fn current(&self, target: Target) -> Option<&str> {
        self.versions.get(&target).map(String::as_str)
    }

    /// The current versions of `targets` as a tuple, `undefined` for one that has none.
    pub fn tuple(&self, targets: &[Target]) -> Expr {
        Expr::Tuple(
            targets
                .iter()
                .map(|target| {
                    self.current(*target)
                        .map_or_else(Expr::undefined, Expr::var)
                })
                .collect(),
        )
    }

    pub fn forget(&mut self, target: Target) {
        self.versions.remove(&target);
    }

    pub fn versions(&self) -> Versions {
        self.versions.clone()
    }

    pub fn restore(&mut self, versions: Versions) {
        self.versions = versions;
    }
}

/// The Erlang variable base name for a TypeScript identifier: an uppercase first letter, and
/// `_` for each character outside `[A-Za-z0-9_]`.
pub fn base_name(name: &str) -> String {
    let mut chars = name.chars();
    let mut base = String::with_capacity(name.len() + 1);
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() => base.push(first.to_ascii_uppercase()),
        Some(first) => {
            base.push('V');
            base.push(sanitize(first));
        }
        None => base.push('V'),
    }
    base.extend(chars.map(sanitize));
    base
}

fn sanitize(c: char) -> char {
    if c.is_ascii_alphanumeric() || c == '_' {
        c
    } else {
        '_'
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_unique_per_base() {
        let mut scope = Scope::default();
        assert_eq!(scope.fresh("Count"), "Count@1");
        assert_eq!(scope.fresh("Count"), "Count@2");
        assert_eq!(scope.temp(), "T@1");
    }

    #[test]
    fn base_names_are_erlang_variables() {
        assert_eq!(base_name("count"), "Count");
        assert_eq!(base_name("_private"), "V_private");
        assert_eq!(base_name("$el"), "V_el");
        assert_eq!(base_name("café"), "Caf_");
    }
}
