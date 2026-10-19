//! A BEAM function takes at most 255 arguments, and the Erlang compiler lifts each fun to
//! a function whose arguments are its parameters and then its free variables. A fun whose
//! two counts add up to more, such as a closure in the body of lodash's `runInContext`,
//! does not compile. Such a fun gets its free variables in one tuple instead:
//!
//! ```erlang
//! begin Env@1 = erlang:list_to_tuple([A, B]), fun(X) -> {A@1, B@1} = Env@1, Body end end
//! ```
//!
//! where `Body` names `A@1` and `B@1`. The tuple comes from a call because `sys_core_fold`
//! would copy a tuple expression into the fun, which brings the captures back. Other funs
//! keep their captures, since the tuple costs an allocation for each closure and a match
//! for each call.

use std::collections::{HashMap, HashSet};

use super::{CatchClause, Clause, Expr, Function};

/// `MAX_FUNC_ARGS` of the Erlang compiler's `beam_validator`.
const MAX_ARGUMENTS: usize = 255;

/// Packs the captures of each fun of `functions` that would exceed `MAX_ARGUMENTS`.
pub fn pack(functions: &mut [Function]) {
    let mut packer = Packer::default();
    for function in functions {
        for clause in &mut function.clauses {
            let mut names = Names::default();
            packer.clause(clause, &mut names);
        }
    }
}

/// The variables that a part of the code reads, and the ones that its patterns bind. A
/// variable that a pattern only compares counts as bound, which keeps it out of the tuple.
#[derive(Default)]
struct Names {
    used: HashSet<String>,
    bound: HashSet<String>,
}

#[derive(Default)]
struct Packer {
    envs: usize,
}

impl Packer {
    fn clause(&mut self, clause: &mut Clause, names: &mut Names) {
        clause.patterns.iter().for_each(|pattern| bind(pattern, names));
        for guard in &mut clause.guards {
            self.expr(guard, names);
        }
        self.body(&mut clause.body, names);
    }

    fn body(&mut self, body: &mut [Expr], names: &mut Names) {
        for expr in body {
            self.expr(expr, names);
        }
    }

    fn expr(&mut self, expr: &mut Expr, names: &mut Names) {
        match expr {
            Expr::Var(name) => {
                if name != "_" {
                    names.used.insert(name.clone());
                }
            }
            Expr::Atom(_)
            | Expr::Integer(_)
            | Expr::Float(_)
            | Expr::Binary(_)
            | Expr::Bytes(_)
            | Expr::JsString(_)
            | Expr::FunRef { .. } => {}
            Expr::Tuple(items) | Expr::List(items) | Expr::Block(items) => self.body(items, names),
            Expr::Cons(heads, tail) => {
                self.body(heads, names);
                self.expr(tail, names);
            }
            Expr::Map(entries) | Expr::MapPattern(entries) => {
                for (key, value) in entries {
                    self.expr(key, names);
                    self.expr(value, names);
                }
            }
            Expr::Call { args, .. } => self.body(args, names),
            Expr::Apply(fun, args) => {
                self.expr(fun, names);
                self.body(args, names);
            }
            Expr::Match(pattern, value) => {
                bind(pattern, names);
                self.expr(value, names);
            }
            Expr::Case(subject, clauses) => {
                self.expr(subject, names);
                for clause in clauses {
                    self.clause(clause, names);
                }
            }
            Expr::Try {
                body,
                catches,
                after,
            } => {
                self.body(body, names);
                for catch in catches {
                    self.catch(catch, names);
                }
                self.body(after, names);
            }
            Expr::Op(_, left, right) => {
                self.expr(left, names);
                self.expr(right, names);
            }
            Expr::Not(value) => self.expr(value, names),
            Expr::Fun { .. } => self.fun(expr, names),
        }
    }

    fn catch(&mut self, catch: &mut CatchClause, names: &mut Names) {
        bind(&catch.class, names);
        bind(&catch.reason, names);
        names.bound.insert(catch.stack.clone());
        self.body(&mut catch.body, names);
    }

    /// Finds the free variables of the fun `expr`, packs them when they are too many, and
    /// adds them to the reads of the code around it.
    fn fun(&mut self, expr: &mut Expr, outer: &mut Names) {
        let Expr::Fun { name, clauses } = expr else {
            return;
        };
        let mut inner = Names::default();
        if let Some(name) = name {
            inner.bound.insert(name.clone());
        }
        for clause in clauses.iter_mut() {
            self.clause(clause, &mut inner);
        }
        let mut free: Vec<String> = inner.used.difference(&inner.bound).cloned().collect();
        let arity = clauses.first().map_or(0, |clause| clause.patterns.len());
        if arity + free.len() <= MAX_ARGUMENTS {
            outer.used.extend(free);
            return;
        }
        // A guard runs before the body unpacks the tuple, so its variables stay captured.
        let mut guarded = Names::default();
        for guard in clauses.iter_mut().flat_map(|clause| clause.guards.iter_mut()) {
            self.expr(guard, &mut guarded);
        }
        free.sort();
        let (packed, kept): (Vec<String>, Vec<String>) = free
            .into_iter()
            .partition(|name| !guarded.used.contains(name));
        self.envs += 1;
        let env = format!("Env@{}", self.envs);
        let renamed: HashMap<String, String> = packed
            .iter()
            .map(|name| (name.clone(), format!("{name}@{}", self.envs)))
            .collect();
        let unpack = Expr::matches(
            Expr::Tuple(packed.iter().map(|name| Expr::var(&renamed[name])).collect()),
            Expr::var(&env),
        );
        for clause in clauses.iter_mut() {
            clause.body.iter_mut().for_each(|expr| rename(expr, &renamed));
            clause.body.insert(0, unpack.clone());
        }
        let fun = std::mem::replace(expr, Expr::Block(Vec::new()));
        *expr = Expr::Block(vec![
            Expr::matches(
                Expr::var(&env),
                Expr::call(
                    "erlang",
                    "list_to_tuple",
                    vec![Expr::List(packed.iter().map(Expr::var).collect())],
                ),
            ),
            fun,
        ]);
        outer.used.extend(packed.into_iter().chain(kept));
        outer.bound.insert(env);
    }
}

/// Records each variable of `pattern` as bound.
fn bind(pattern: &Expr, names: &mut Names) {
    match pattern {
        Expr::Var(name) => {
            names.bound.insert(name.clone());
        }
        Expr::Tuple(items) | Expr::List(items) | Expr::Block(items) => {
            items.iter().for_each(|item| bind(item, names));
        }
        Expr::Cons(heads, tail) => {
            heads.iter().for_each(|item| bind(item, names));
            bind(tail, names);
        }
        Expr::Map(entries) | Expr::MapPattern(entries) => {
            for (key, value) in entries {
                bind(key, names);
                bind(value, names);
            }
        }
        Expr::Match(left, right) | Expr::Op(_, left, right) => {
            bind(left, names);
            bind(right, names);
        }
        _ => {}
    }
}

/// Renames the variables of `expr` that `renamed` maps. A packed variable is free in the
/// fun, so no pattern inside it binds the name, and every occurrence reads the capture.
fn rename(expr: &mut Expr, renamed: &HashMap<String, String>) {
    let all = |items: &mut [Expr]| items.iter_mut().for_each(|item| rename(item, renamed));
    match expr {
        Expr::Var(name) => {
            if let Some(new) = renamed.get(name) {
                name.clone_from(new);
            }
        }
        Expr::Atom(_)
        | Expr::Integer(_)
        | Expr::Float(_)
        | Expr::Binary(_)
        | Expr::Bytes(_)
        | Expr::JsString(_)
        | Expr::FunRef { .. } => {}
        Expr::Tuple(items) | Expr::List(items) | Expr::Block(items) => all(items),
        Expr::Call { args, .. } => all(args),
        Expr::Cons(heads, tail) => {
            all(heads);
            rename(tail, renamed);
        }
        Expr::Map(entries) | Expr::MapPattern(entries) => {
            for (key, value) in entries {
                rename(key, renamed);
                rename(value, renamed);
            }
        }
        Expr::Apply(fun, args) => {
            rename(fun, renamed);
            all(args);
        }
        Expr::Match(left, right) | Expr::Op(_, left, right) => {
            rename(left, renamed);
            rename(right, renamed);
        }
        Expr::Not(value) => rename(value, renamed),
        Expr::Case(subject, clauses) => {
            rename(subject, renamed);
            clauses
                .iter_mut()
                .for_each(|clause| rename_clause(clause, renamed));
        }
        Expr::Fun { clauses, .. } => clauses
            .iter_mut()
            .for_each(|clause| rename_clause(clause, renamed)),
        Expr::Try {
            body,
            catches,
            after,
        } => {
            all(body);
            for catch in catches {
                all(&mut catch.body);
            }
            all(after);
        }
    }
}

fn rename_clause(clause: &mut Clause, renamed: &HashMap<String, String>) {
    clause
        .patterns
        .iter_mut()
        .chain(clause.guards.iter_mut())
        .chain(clause.body.iter_mut())
        .for_each(|expr| rename(expr, renamed));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capturing(count: usize) -> (Vec<Expr>, Expr) {
        let vars: Vec<Expr> = (0..count).map(|i| Expr::var(format!("V{i}"))).collect();
        let binds = vars
            .iter()
            .map(|var| Expr::matches(var.clone(), Expr::call("erlang", "make_ref", vec![])))
            .collect();
        let fun = Expr::Fun {
            name: None,
            clauses: vec![Clause::new(Expr::var("X"), vec![Expr::List(vars)])],
        };
        (binds, fun)
    }

    fn packed(count: usize) -> Expr {
        let (mut body, fun) = capturing(count);
        body.push(fun);
        let mut functions = vec![Function {
            name: "f".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body,
            }],
        }];
        pack(&mut functions);
        functions.remove(0).clauses.remove(0).body.pop().expect("the fun")
    }

    #[test]
    fn a_fun_within_the_limit_keeps_its_captures() {
        assert!(matches!(packed(254), Expr::Fun { .. }));
    }

    #[test]
    fn a_fun_over_the_limit_reads_its_captures_from_one_tuple() {
        let Expr::Block(parts) = packed(255) else {
            panic!("the fun is not packed");
        };
        let [Expr::Match(env, tuple), Expr::Fun { clauses, .. }] = parts.as_slice() else {
            panic!("unexpected shape {parts:?}");
        };
        assert_eq!(**env, Expr::var("Env@1"));
        let Expr::Call { args, .. } = &**tuple else {
            panic!("the tuple is not built by a call");
        };
        assert!(matches!(args.as_slice(), [Expr::List(items)] if items.len() == 255));
        let body = &clauses[0].body;
        assert_eq!(body.len(), 2);
        let Expr::List(items) = &body[1] else {
            panic!("the body changed shape");
        };
        assert!(items.iter().all(|item| matches!(item, Expr::Var(name) if name.ends_with("@1"))));
    }
}
