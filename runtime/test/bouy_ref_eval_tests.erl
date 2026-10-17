-module(bouy_ref_eval_tests).

-include_lib("eunit/include/eunit.hrl").

%% Source text that is only comments, or one regular expression literal,
%% runs without the compiler: test262's character sweeps evaluate 65,536 of
%% them. Other code still needs the compiler, which this VM does not have.
trivial_sources_need_no_compiler_test() ->
    {Empty, Hashbang, Pattern, Code, BadFlags} = in_realm(fun() ->
        Eval = fun(Source) -> bouy_ref_eval:method(<<"globalThis">>, <<"eval">>, undefined, [Source]) end,
        RegExp = Eval(<<"/a[/]b/gi">>),
        {[Eval(S) || S <- [<<>>, <<" \t// only a comment">>, <<"/* block */\n">>]],
         Eval(<<"#!hashbang">>),
         {bouy_ref:get(RegExp, <<"source">>), bouy_ref:get(RegExp, <<"flags">>)},
         error_name(fun() -> Eval(<<"/a/ + 1">>) end),
         error_name(fun() -> Eval(<<"/a/gg">>) end)}
    end),
    ?assertEqual([undefined, undefined, undefined], Empty),
    ?assertEqual(undefined, Hashbang),
    ?assertEqual({<<"a[/]b">>, <<"gi">>}, Pattern),
    ?assertEqual(<<"TypeError">>, Code),
    ?assertEqual(<<"TypeError">>, BadFlags).

%% CanDeclareGlobalFunction: eval code declares no function when one of its
%% names cannot be declared, such as the non-configurable NaN.
global_functions_declare_all_or_nothing_test() ->
    {Name, Declared} = in_realm(fun() ->
        F = bouy_ref_realm:builtin(<<"f">>, fun(_, _) -> undefined end),
        Error = error_name(fun() -> bouy_ref_realm:declare_globals([], [{<<"fresh">>, F}, {<<"NaN">>, F}], true) end),
        {Error, bouy_heap:get_own({'$o', 'globalThis'}, <<"fresh">>)}
    end),
    ?assertEqual(<<"TypeError">>, Name),
    ?assertEqual(none, Declared).

%% The global declarative record: a script's let and const shadow the global
%% object, are in their dead zone until the script declares them, and keep
%% later scripts and eval code from declaring their names again. A script may
%% not declare a lexical name that is a non-configurable global either.
script_lexical_declarations_test() ->
    Results = in_realm(fun() ->
        ok = bouy_ref_realm:declare_script(script_a, [{<<"x">>, mutable}, {<<"k">>, immutable}], [<<"v">>], []),
        Dead = error_name(fun() -> bouy_ref_realm:global(<<"x">>) end),
        put({'$m', script_a, <<"x">>}, {v, 1}),
        put({'$m', script_a, <<"k">>}, {v, 2}),
        Read = bouy_ref_realm:global(<<"x">>),
        Written = bouy_ref_realm:set_global(<<"x">>, 3, sloppy),
        {Dead, Read, Written, get({'$m', script_a, <<"x">>}),
         error_name(fun() -> bouy_ref_realm:set_global(<<"k">>, 4, sloppy) end),
         bouy_ref_realm:delete_global(<<"x">>),
         bouy_heap:get_own({'$o', 'globalThis'}, <<"x">>),
         [error_name(fun() -> bouy_ref_realm:declare_script(script_b, [{Name, mutable}], [], []) end)
          || Name <- [<<"x">>, <<"v">>, <<"undefined">>]],
         error_name(fun() -> bouy_ref_realm:declare_globals([<<"k">>], [], true) end),
         error_name(fun() -> bouy_ref_realm:set_resolved(<<"missing">>, 1, false) end)}
    end),
    ?assertEqual({<<"ReferenceError">>, 1, 3, {v, 3}, <<"TypeError">>, false, none,
                  [<<"SyntaxError">>, <<"SyntaxError">>, <<"SyntaxError">>],
                  <<"SyntaxError">>, <<"ReferenceError">>}, Results).

in_realm(Run) ->
    Self = self(),
    Compiler = os:getenv("BOUY_COMPILER"),
    true = os:unsetenv("BOUY_COMPILER"),
    {Pid, Ref} = spawn_monitor(fun() ->
        ok = bouy_ref_realm:install(),
        Self ! {self(), Run()}
    end),
    try
        receive
            {Pid, Result} -> Result;
            {'DOWN', Ref, process, Pid, Reason} -> error(Reason)
        end
    after
        Compiler =:= false orelse os:putenv("BOUY_COMPILER", Compiler)
    end.

error_name(Run) ->
    try Run() of
        Value -> {no_error, Value}
    catch
        error:{'$throw', Error} -> bouy_ref:get(Error, <<"name">>)
    end.
