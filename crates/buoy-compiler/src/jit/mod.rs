//! The compiler side of the native tier (section 17.11 of the contract).
//!
//! An island is a function whose parameters and result are numbers or booleans and whose
//! whole call graph is typed code that this module lowers: numbers, booleans, strings,
//! instances of the classes of the module, and arrays of those. Its code calls nothing
//! outside the island. It may read and write variables outside itself and the objects
//! that they hold, and read the static fields of its classes: the entry passes their
//! values in, and a run that returns writes the variables and the objects back, so a run
//! changes what other code can see only as the Erlang code would. The reference lowering
//! starts such a function with `buoy_jit:enter/4`, which runs the machine code when the
//! values have their types, and else runs the Erlang code that it always emits too.
//!
//! The entry checks at run time what the compiler cannot know: the type of each argument,
//! of each value outside the island that the code uses, and of every object that those
//! reach, and that no code replaced a method of a class or a property of the prototypes
//! the island relies on.

mod body;
mod island;

use std::collections::{HashMap, HashSet};

use oxc::ast::AstKind;
use oxc::ast::ast::{Expression, Function};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{Semantic, SymbolId};

pub use island::Global;
use island::Island;

/// The islands of a module.
#[derive(Debug, Default)]
pub struct Plan {
    /// The entries, by the offset where the body of the function starts.
    pub entries: HashMap<u32, Entry>,
    /// The encoded IR of each island, by its index.
    pub programs: Vec<Vec<u8>>,
    /// The classes whose definitions an entry checks, which the lowering seals.
    pub sealed: HashSet<SymbolId>,
}

/// What the entry of an island checks and passes.
#[derive(Debug, Clone)]
pub struct Entry {
    /// The index of the island, the argument of `'$jit'/1`.
    pub index: usize,
    /// The values that the entry passes to the machine code, in order.
    pub globals: Vec<Global>,
    /// The variables that a run that returns writes back, in order.
    pub written: Vec<Global>,
    /// The classes of the island in the order of their ids, with the keys of their
    /// fields. Their definitions must be unchanged.
    pub classes: Vec<(SymbolId, Vec<String>)>,
    /// Whether the code calls `Math`, which must be the intrinsic, unchanged.
    pub uses_math: bool,
}

/// The islands of a module, from the nodes of its semantic analysis.
#[must_use]
pub fn plan(semantic: &Semantic<'_>) -> Plan {
    let mut plan = Plan::default();
    let mut candidates = Vec::new();
    for node in semantic.nodes().iter() {
        match node.kind() {
            AstKind::Function(function) if function.is_declaration() && is_candidate(function) => {
                candidates.push(function);
            }
            // A direct eval or a `with` statement can rebind any name of the code around it.
            AstKind::WithStatement(_) => return plan,
            AstKind::CallExpression(call) if matches!(&call.callee, Expression::Identifier(ident) if ident.name == "eval") =>
            {
                return plan;
            }
            _ => {}
        }
    }
    let trace = std::env::var_os("BUOY_JIT_TRACE").is_some();
    for function in candidates {
        let (Some(id), Some(body)) = (&function.id, &function.body) else {
            continue;
        };
        let name = id.name.as_str();
        match Island::new(semantic).compile(id.symbol_id(), function) {
            Ok(built) => {
                if trace {
                    eprintln!("buoy jit: {name} is an island");
                }
                plan.sealed
                    .extend(built.classes.iter().map(|(symbol, _)| *symbol));
                let index = plan.programs.len();
                plan.programs.push(built.program.encode());
                plan.entries.insert(
                    body.span.start,
                    Entry {
                        index,
                        globals: built.globals,
                        written: built.written,
                        classes: built.classes,
                        uses_math: built.uses_math,
                    },
                );
            }
            Err(reason) if trace => eprintln!("buoy jit: {name}: {}", reason.0),
            Err(_) => {}
        }
    }
    plan
}

/// A function that takes typed numbers or booleans and returns one, and that loops or
/// calls: a call of a function that does neither costs less in the Erlang tier than the
/// switch into native code.
fn is_candidate(function: &Function<'_>) -> bool {
    if function.r#async || function.generator || function.body.is_none() {
        return false;
    }
    let primitive = |annotation: Option<&oxc::ast::ast::TSTypeAnnotation<'_>>| {
        annotation.is_some_and(|annotation| {
            matches!(
                annotation.type_annotation,
                oxc::ast::ast::TSType::TSNumberKeyword(_)
                    | oxc::ast::ast::TSType::TSBooleanKeyword(_)
            )
        })
    };
    let params = function
        .params
        .items
        .iter()
        .all(|param| primitive(param.type_annotation.as_deref()));
    let result = function.return_type.as_deref().is_some_and(|annotation| {
        primitive(Some(annotation))
            || matches!(
                annotation.type_annotation,
                oxc::ast::ast::TSType::TSVoidKeyword(_)
            )
    });
    let mut work = Work(false);
    if let Some(body) = &function.body {
        work.visit_function_body(body);
    }
    params && result && work.0
}

/// Whether a body has a loop or a call.
struct Work(bool);

impl<'a> Visit<'a> for Work {
    fn visit_statement(&mut self, statement: &oxc::ast::ast::Statement<'a>) {
        use oxc::ast::ast::Statement;
        if matches!(
            statement,
            Statement::ForStatement(_)
                | Statement::ForOfStatement(_)
                | Statement::WhileStatement(_)
                | Statement::DoWhileStatement(_)
        ) {
            self.0 = true;
        }
        walk::walk_statement(self, statement);
    }

    fn visit_call_expression(&mut self, call: &oxc::ast::ast::CallExpression<'a>) {
        self.0 = true;
        walk::walk_call_expression(self, call);
    }
}

#[cfg(test)]
mod tests;
