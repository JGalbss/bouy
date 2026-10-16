//! Section 11 of the contract: library imports and globals, and the Erlang modules behind them.

/// What a library import or a global names on the Erlang side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Binding {
    /// A namespace module: `Ns.f(args)` is `Module:'f'(Args)`.
    Namespace(&'static str),
    /// A function: `f(args)` is `Module:'f'(Args)`.
    Function {
        module: &'static str,
        function: &'static str,
    },
    /// A global error class in `bouy_error`, such as `TypeError`.
    ErrorClass(&'static str),
    /// `Boolean`, which converts to a boolean.
    Boolean,
    /// `undefined`, `NaN`, or `Infinity`.
    Constant(&'static str),
    /// `structuredClone`.
    StructuredClone,
    /// `process`, of which only `process.env.NAME` and `process.argv` exist.
    Process,
    /// A host API that Bouy does not provide (error `BOUY207`).
    HostApi,
}

const BOUY_FUNCTIONS: &[&str] = &[
    "spawn",
    "cast",
    "stop",
    "inspect",
    "supervise",
    "child",
    "schedule",
    "cancelSchedule",
    "sleep",
    "withTimeout",
    "self",
];

const EFFECT_NAMESPACES: &[(&str, &str)] = &[
    ("Effect", "bouy_effect"),
    ("Data", "bouy_data"),
    ("Schedule", "bouy_schedule"),
    ("Schema", "bouy_schema"),
    ("Console", "bouy_effect_console"),
    ("Duration", "bouy_duration"),
];

const AI_FUNCTIONS: &[&str] = &[
    "generateText",
    "streamText",
    "tool",
    "stepCountIs",
    "jsonSchema",
];

const OPENAI_FUNCTIONS: &[&str] = &["openai", "createOpenAI"];

/// Whether `specifier` names a library rather than a Bouy module.
pub fn is_library(specifier: &str) -> bool {
    matches!(specifier, "bouy" | "effect" | "ai" | "@ai-sdk/openai")
        || effect_submodule(specifier).is_some()
}

/// The binding of `import { name } from "specifier"`.
pub fn named_import(specifier: &str, name: &str) -> Option<Binding> {
    match specifier {
        "bouy" => BOUY_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "bouy",
                function,
            }),
        "effect" if name == "pipe" => Some(Binding::Function {
            module: "bouy_effect",
            function: "pipe",
        }),
        "effect" => EFFECT_NAMESPACES
            .iter()
            .find(|(export, _)| *export == name)
            .map(|(_, module)| Binding::Namespace(module)),
        "ai" => AI_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "bouy_ai",
                function,
            }),
        "@ai-sdk/openai" => OPENAI_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "bouy_ai_openai",
                function,
            }),
        _ => None,
    }
}

/// The binding of `import * as X from "specifier"`.
pub fn namespace_import(specifier: &str) -> Option<Binding> {
    effect_submodule(specifier).map(Binding::Namespace)
}

fn effect_submodule(specifier: &str) -> Option<&'static str> {
    let export = specifier.strip_prefix("effect/")?;
    EFFECT_NAMESPACES
        .iter()
        .find(|(name, _)| *name == export)
        .map(|(_, module)| *module)
}

/// The binding of an identifier that no declaration in the module resolves.
pub fn global(name: &str) -> Option<Binding> {
    let binding = match name {
        "console" => Binding::Namespace("bouy_console"),
        "Math" => Binding::Namespace("bouy_math"),
        "JSON" => Binding::Namespace("bouy_json"),
        "Object" => Binding::Namespace("bouy_object"),
        "Array" => Binding::Namespace("bouy_array"),
        "Number" => Binding::Namespace("bouy_number"),
        "String" => Binding::Namespace("bouy_string"),
        "Date" => Binding::Namespace("bouy_date"),
        "Promise" => Binding::Namespace("bouy_task"),
        "Map" => Binding::Namespace("bouy_map"),
        "Set" => Binding::Namespace("bouy_set"),
        "Error" | "TypeError" | "RangeError" | "SyntaxError" => {
            Binding::ErrorClass(error_class_name(name))
        }
        "Boolean" => Binding::Boolean,
        "parseInt" | "parseFloat" => Binding::Function {
            module: "bouy_number",
            function: if name == "parseInt" {
                "parseInt"
            } else {
                "parseFloat"
            },
        },
        "isNaN" => Binding::Function {
            module: "bouy_number",
            function: "$isNaN",
        },
        "isFinite" => Binding::Function {
            module: "bouy_number",
            function: "$isFinite",
        },
        "undefined" => Binding::Constant("undefined"),
        "NaN" => Binding::Constant("NaN"),
        "Infinity" => Binding::Constant("Infinity"),
        "structuredClone" => Binding::StructuredClone,
        "process" => Binding::Process,
        "setTimeout" | "setInterval" | "setImmediate" | "queueMicrotask" | "globalThis"
        | "clearTimeout" | "clearInterval" => Binding::HostApi,
        _ => return None,
    };
    Some(binding)
}

fn error_class_name(name: &str) -> &'static str {
    match name {
        "TypeError" => "TypeError",
        "RangeError" => "RangeError",
        "SyntaxError" => "SyntaxError",
        _ => "Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_library_imports() {
        assert!(is_library("effect/Effect"));
        assert!(!is_library("lodash"));
        assert_eq!(
            named_import("effect", "Effect"),
            Some(Binding::Namespace("bouy_effect"))
        );
        assert_eq!(named_import("bouy", "nope"), None);
        assert_eq!(
            namespace_import("effect/Schema"),
            Some(Binding::Namespace("bouy_schema"))
        );
    }
}
