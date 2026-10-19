%% internalBinding('cjs_lexer') (src/node_cjs_lexer.cc): the export names of
%% CommonJS source text, which Node's ESM loader reads to give an import of
%% a CommonJS module its named exports. Buoy's compiler finds them as Node's
%% cjs-module-lexer does, the same analysis that it runs when it links an
%% import of a CommonJS module of the program.
-module(buoy_binding_cjs_lexer).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    buoy_node:object([{<<"parse">>, buoy_node:fn(<<"parse">>, 1, fun(_, Args) -> parse(buoy_node:arg(1, Args)) end)}]).

%% parse(source): [exports, reexports], a Set of the export names and an
%% array of the re-exported specifiers.
parse(Source) ->
    {Names, Reexports} = buoy_ref_eval:cjs_lexer(buoy_ref:to_string(Source)),
    Set = buoy_ref_realm:global(<<"Set">>),
    Exports = buoy_heap:construct(Set, [buoy_heap:new_array([buoy_node:string(N) || N <- Names])], Set),
    buoy_heap:new_array([Exports, buoy_heap:new_array([buoy_node:string(R) || R <- Reexports])]).
