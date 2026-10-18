# The entry points of an npm package, from the fields of its package.json. The input of
# `kind` and `format` is the object {platform, type, main, module, types, exports} that
# `entry` builds from a package.json. scripts/rank-packages.sh and scripts/ecosystem.sh
# include this file with `jq -L scripts 'include "package-entry"; ...'`.

def entry:
    {
        platform: ((.os // []) + (.cpu // []) | length > 0),
        type: (.type // "commonjs"),
        main: (.main // null),
        module: (.module // null),
        types: (.types // .typings // null),
        exports: (.exports // null)
    };

# The (condition path, target) pairs of an exports field.
def targets:
    if type == "string" then [{path: [], target: .}]
    else [paths(type == "string") as $path | {path: $path, target: getpath($path)}] end;

def declaration: test("\\.d\\.[cm]?ts$");

# `platform-binary` when the package names `os` or `cpu`, `types-only` when its entry points
# name only type declarations, and `program` otherwise.
def kind:
    if .platform then "platform-binary"
    else
        ([.main, .module] + (if .exports == null then [] else (.exports | targets | map(.target)) end)
            | map(select(. != null and . != "" and (declaration | not)))) as $code
        | if ($code | length) == 0 and .types != null and (.exports != null or .main == "")
          then "types-only" else "program" end
    end;

# `esm` when every entry point is an ES module, `cjs` when none is, and `dual`.
def format:
    (if .exports == null then [] else (.exports | targets) end) as $targets
    | ($targets | map(select(.target | declaration | not))) as $code
    | (($code | any(.path | index("require") != null) or any(.target | test("\\.cjs$")))
        or (.main // "" | test("\\.cjs$"))) as $require
    | (($code | any(.path | index("import") != null) or any(.target | test("\\.mjs$")))
        or .module != null) as $import
    | if .type == "module" then (if $require then "dual" else "esm" end)
      else (if $import then "dual" else "cjs" end) end;
