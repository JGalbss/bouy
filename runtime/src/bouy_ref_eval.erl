%% eval and the Function constructor: code that a program makes at run time.
%%
%% The runtime has no compiler of its own. It hands the source text to the
%% Bouy binary that BOUY_COMPILER names (`bouy compile-eval`), which prints an
%% Erlang module, and loads that module into the VM. The module's
%% '__eval__'/1 runs the code in the calling realm with a this and returns its
%% completion value. A source text compiles once per VM.
%%
%% shortcut: direct eval runs as global code, so the code does not see the
%% local variables of its caller. Doing better needs the compiler to know the
%% scope of the call.
-module(bouy_ref_eval).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, direct/4, create_function/1, create_function/2]).

-import(bouy_ref, [type_error/1]).

-define(GLOBAL, {'$o', 'globalThis'}).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"eval">>, eval_function()}].

eval_function() ->
    bouy_ref_realm:builtin(<<"eval">>, <<"eval">>, 1, fun(This, Args) -> ?MODULE:method(<<"globalThis">>, <<"eval">>, This, Args) end).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"globalThis">>, <<"eval">>, _This, Args) -> indirect(bouy_ref_realm:arg(1, Args)).

%% PerformEval of an indirect eval: global code, sloppy unless it says
%% otherwise.
indirect(Source) when ?IS_STRING(Source) -> run(Source, [], ?GLOBAL);
indirect(Value) -> Value.

%% `eval(...)` where eval is the name of the global: a direct eval when it
%% still is the intrinsic, else a plain call.
%% A direct eval in a parameter default (sloppy_parameters) may not declare
%% `arguments`.
-spec direct(term(), list(), strict | sloppy | sloppy_parameters, term()) -> term().
direct({'$f', {builtin, <<"eval">>}, _}, Args, Mode, This) ->
    Flags = case Mode of
        strict -> ["--strict"];
        sloppy -> [];
        sloppy_parameters -> ["--parameters"]
    end,
    case bouy_ref_realm:arg(1, Args) of
        Source when ?IS_STRING(Source) -> run(Source, Flags, This);
        Value -> Value
    end;
direct(F, Args, _Mode, _This) ->
    bouy_ref:call(F, undefined, Args).

%% CreateDynamicFunction: new Function(p1, ..., body).
-spec create_function(list()) -> term().
create_function(Args) -> create_function(normal, Args).

%% CreateDynamicFunction of a kind: normal, generator, async, or
%% async_generator.
-spec create_function(normal | generator | async | async_generator, list()) -> term().
create_function(Kind, Args) ->
    {Params, Body} = case Args of
        [] -> {[], <<>>};
        _ -> {lists:droplast(Args), lists:last(Args)}
    end,
    P = bouy_ref_string:concat(lists:join(<<",">>, [bouy_ref:to_string(A) || A <- Params])),
    B = bouy_ref:to_string(Body),
    Prefix = case Kind of
        normal -> <<"(function anonymous(">>;
        generator -> <<"(function* anonymous(">>;
        async -> <<"(async function anonymous(">>;
        async_generator -> <<"(async function* anonymous(">>
    end,
    Source = bouy_ref_string:concat([Prefix, P, <<"\n) {\n">>, B, <<"\n})">>]),
    run(Source, ["--function"], ?GLOBAL).

%% Flags are the options of `bouy compile-eval`.
run(Source, Flags, This) ->
    Key = {?MODULE, erlang:md5(term_to_binary({Source, Flags}))},
    Module = case persistent_term:get(Key, undefined) of
        undefined ->
            M = compile(Source, Flags),
            persistent_term:put(Key, M),
            M;
        M ->
            M
    end,
    Module:'__eval__'(This).

compile(Source, Flags) ->
    Compiler = case os:getenv("BOUY_COMPILER") of
        false -> type_error(<<"eval and new Function need the Bouy compiler: run the program with `bouy run`">>);
        C -> C
    end,
    Name = "bouy_eval_" ++ integer_to_list(erlang:unique_integer([positive])),
    File = filename:join(temp_dir(), Name ++ ".js"),
    ok = file:write_file(File, bouy_ref_string:to_utf8(Source)),
    Args = ["compile-eval"] ++ Flags ++ [Name, File],
    Port = open_port({spawn_executable, Compiler}, [{args, Args}, binary, exit_status, stream, use_stdio, hide]),
    {Status, Output} = collect(Port, []),
    _ = file:delete(File),
    case Status of
        0 -> load(list_to_atom(Name), Output);
        2 -> report(Output);
        _ -> type_error(bouy_ref_string:from_utf8(<<"the Bouy compiler failed: ", Output/binary>>))
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} -> {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

%% The compiler reports a diagnostic as <ErrorName>\t<message>.
-spec report(binary()) -> no_return().
report(Output) ->
    {Name, Message} = case binary:split(Output, <<"\t">>) of
        [<<"SyntaxError">>, M] -> {'SyntaxError', M};
        [_, M] -> {'TypeError', M};
        [M] -> {'TypeError', M}
    end,
    bouy_heap:throw_error(Name, bouy_ref_string:from_utf8(Message)).

load(Module, Erlang) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Erlang)),
    Forms = [Form || FormTokens <- split_forms(Tokens, [], []), {ok, Form} <- [erl_parse:parse_form(FormTokens)]],
    case compile:forms(Forms, [binary, return_errors, nowarn_unused_vars, nowarn_unused_function]) of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
            Module;
        Error ->
            type_error(bouy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("the Erlang compiler rejected eval code: ~0tP", [Error, 8]))))
    end.

split_forms([], [], Forms) -> lists:reverse(Forms);
split_forms([], Current, Forms) -> lists:reverse([lists:reverse(Current) | Forms]);
split_forms([{dot, _} = Dot | Rest], Current, Forms) -> split_forms(Rest, [], [lists:reverse([Dot | Current]) | Forms]);
split_forms([Token | Rest], Current, Forms) -> split_forms(Rest, [Token | Current], Forms).
