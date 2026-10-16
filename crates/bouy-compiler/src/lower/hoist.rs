//! Nested function declarations (section 12). JavaScript creates each one when its block
//! starts, and the function reads the variables of the block as they are when it runs. An
//! Erlang fun copies the values it captures, so Bouy creates the function as late as it can:
//! just before the first statement of its block that uses it. Functions that call each other
//! are created together, as one recursive group.

use std::collections::{HashMap, HashSet};

use oxc::ast::ast::{Function, Statement};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, Span};

/// Function declarations of one block that are created together, before the statement at
/// `position`.
#[derive(Debug)]
pub struct Group<'a> {
    pub position: usize,
    /// One function, or functions that call each other.
    pub functions: Vec<&'a Function<'a>>,
    /// A variable of the block that a function reads and that the block declares at or after
    /// `position`, with the place of the first use of the group.
    pub declared_late: Option<(SymbolId, Span)>,
}

struct Member<'a> {
    function: &'a Function<'a>,
    symbol: SymbolId,
    /// The index of the declaration statement.
    index: usize,
}

/// The groups of the function declarations among `statements` that `nested` accepts, in the
/// order to create them. `statements` is one flattened block.
pub fn groups<'a>(
    statements: &[&'a Statement<'a>],
    semantic: &Semantic<'_>,
    nested: impl Fn(&Function<'a>) -> bool,
) -> Vec<Group<'a>> {
    let members = members(statements, nested);
    if members.is_empty() {
        return Vec::new();
    }
    let usage = usage(statements, semantic, &members);
    let components = components(&usage.calls);
    let positions = positions(&components, &usage);
    let declared: Vec<(SymbolId, usize)> = statements
        .iter()
        .enumerate()
        .flat_map(|(index, statement)| {
            declared_symbols(statement)
                .into_iter()
                .map(move |symbol| (symbol, index))
        })
        .collect();
    components
        .iter()
        .zip(positions)
        .map(|(component, position)| {
            let functions: Vec<&'a Function<'a>> = component
                .iter()
                .map(|member| members[*member].function)
                .collect();
            // A function that nothing uses is created at its declaration.
            let Some((index, first)) = position else {
                let index = component
                    .iter()
                    .map(|member| members[*member].index)
                    .min()
                    .unwrap_or(0);
                return Group {
                    position: index,
                    functions,
                    declared_late: None,
                };
            };
            let declared_late = declared
                .iter()
                .filter(|(_, at)| *at >= index)
                .find(|(symbol, _)| {
                    functions
                        .iter()
                        .any(|function| reads(semantic, *symbol, function.span))
                })
                .map(|(symbol, _)| (*symbol, first));
            Group {
                position: index,
                functions,
                declared_late,
            }
        })
        .collect()
}

fn members<'a>(
    statements: &[&'a Statement<'a>],
    nested: impl Fn(&Function<'a>) -> bool,
) -> Vec<Member<'a>> {
    statements
        .iter()
        .enumerate()
        .filter_map(|(index, statement)| match statement {
            Statement::FunctionDeclaration(function)
                if function.body.is_some() && nested(function) =>
            {
                let symbol = function.id.as_ref()?.symbol_id.get()?;
                Some(Member {
                    function,
                    symbol,
                    index,
                })
            }
            _ => None,
        })
        .collect()
}

/// How the statements of a block use its function declarations.
struct Usage {
    /// For each member: the first statement outside every member that uses it, and the
    /// place of that use.
    first_use: Vec<Option<(usize, Span)>>,
    /// For each member: the members that its body uses.
    calls: Vec<HashSet<usize>>,
}

fn usage(statements: &[&Statement<'_>], semantic: &Semantic<'_>, members: &[Member<'_>]) -> Usage {
    let mut usage = Usage {
        first_use: vec![None; members.len()],
        calls: vec![HashSet::new(); members.len()],
    };
    for (used, member) in members.iter().enumerate() {
        for reference in semantic.scoping().get_resolved_references(member.symbol) {
            let at = semantic.reference_span(reference);
            if let Some(user) = members
                .iter()
                .position(|other| contains(other.function.span, at))
            {
                if user != used {
                    usage.calls[user].insert(used);
                }
                continue;
            }
            if let Some(index) = statements
                .iter()
                .position(|statement| contains(statement.span(), at))
                && usage.first_use[used].is_none_or(|(first, _)| index < first)
            {
                usage.first_use[used] = Some((index, at));
            }
        }
    }
    usage
}

/// The statement before which each component is created: no later than its first use, and
/// no later than a component whose functions use it. `components` lists a used component
/// before its users.
fn positions(components: &[Vec<usize>], usage: &Usage) -> Vec<Option<(usize, Span)>> {
    let mut positions: Vec<Option<(usize, Span)>> = components
        .iter()
        .map(|component| {
            component
                .iter()
                .filter_map(|member| usage.first_use[*member])
                .min_by_key(|(index, _)| *index)
        })
        .collect();
    let component_of: HashMap<usize, usize> = components
        .iter()
        .enumerate()
        .flat_map(|(number, component)| component.iter().map(move |member| (*member, number)))
        .collect();
    for number in (0..components.len()).rev() {
        let Some(own) = positions[number] else {
            continue;
        };
        let dependencies: HashSet<usize> = components[number]
            .iter()
            .flat_map(|member| {
                usage.calls[*member]
                    .iter()
                    .map(|callee| component_of[callee])
            })
            .filter(|dependency| *dependency != number)
            .collect();
        for dependency in dependencies {
            if positions[dependency].is_none_or(|(index, _)| own.0 < index) {
                positions[dependency] = Some(own);
            }
        }
    }
    positions
}

/// Whether code in `span` reads `symbol`.
fn reads(semantic: &Semantic<'_>, symbol: SymbolId, span: Span) -> bool {
    semantic
        .scoping()
        .get_resolved_references(symbol)
        .any(|reference| contains(span, semantic.reference_span(reference)))
}

/// The variables, classes, and functions that `statement` declares in its block.
fn declared_symbols(statement: &Statement<'_>) -> Vec<SymbolId> {
    match statement {
        Statement::VariableDeclaration(variables) => variables
            .declarations
            .iter()
            .flat_map(|declarator| declarator.id.get_binding_identifiers())
            .filter_map(|id| id.symbol_id.get())
            .collect(),
        Statement::ClassDeclaration(class) => class
            .id
            .iter()
            .filter_map(|id| id.symbol_id.get())
            .collect(),
        _ => Vec::new(),
    }
}

/// The strongly connected components of the graph where each member uses the members in
/// `uses`, ordered so that a component comes after every component it uses.
fn components(uses: &[HashSet<usize>]) -> Vec<Vec<usize>> {
    let reaches = |from: usize, to: usize| {
        let mut seen = HashSet::from([from]);
        let mut stack = vec![from];
        while let Some(member) = stack.pop() {
            if member == to {
                return true;
            }
            for next in &uses[member] {
                if seen.insert(*next) {
                    stack.push(*next);
                }
            }
        }
        false
    };
    let mut assigned = vec![false; uses.len()];
    let mut components = Vec::new();
    for member in 0..uses.len() {
        if assigned[member] {
            continue;
        }
        let component: Vec<usize> = (member..uses.len())
            .filter(|other| {
                !assigned[*other]
                    && (*other == member || reaches(member, *other) && reaches(*other, member))
            })
            .collect();
        for other in &component {
            assigned[*other] = true;
        }
        components.push(component);
    }
    // A component that uses another goes after it.
    let mut ordered: Vec<Vec<usize>> = Vec::with_capacity(components.len());
    let mut placed = vec![false; components.len()];
    while ordered.len() < components.len() {
        for (number, component) in components.iter().enumerate() {
            if placed[number] {
                continue;
            }
            let ready = component.iter().all(|member| {
                uses[*member].iter().all(|used| {
                    component.contains(used) || ordered.iter().any(|done| done.contains(used))
                })
            });
            if ready {
                placed[number] = true;
                ordered.push(component.clone());
            }
        }
    }
    ordered
}

fn contains(outer: Span, inner: Span) -> bool {
    outer.start <= inner.start && inner.end <= outer.end
}
