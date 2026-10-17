%% eval and the Function constructor: code that a program makes at run time.
%%
%% The runtime has no compiler of its own. It hands the source text to the
%% Bouy binary that BOUY_COMPILER names (`bouy compile-eval`), which prints an
%% Erlang module, and loads that module into the VM. The module's
%% '__eval__'/3 runs the code in the calling realm with a this, the scope of
%% the caller, and the context of the call, and returns its completion value.
%% A source text compiles once per VM for each list of flags.
%%
%% A sloppy function that calls eval directly gets an object for the `var`
%% names and functions that its eval code declares (var_object/0), which the
%% compiler treats as a `with` object around the function's body.
-module(bouy_ref_eval).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, direct/7, var_object/0, declare_vars/3, create_function/1, create_function/2, script/1, warm_up/0]).

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
indirect(Source) when ?IS_STRING(Source) -> run(Source, [], ?GLOBAL, [], #{});
indirect(Value) -> Value.

%% `eval(...)` where eval is the name of the global: a direct eval when it
%% still is the intrinsic, else a plain call.
%% Scope holds the caller's scope innermost first: [{Name, Cell}] for its
%% bindings (a copy for an immutable one, whose name starts with `!`), with
%% {<<"@with">>, Object} for a `with` object and
%% {<<"@vars">>, Object} for the variables of a function. Lexical holds the
%% names that sloppy eval code may not declare with `var`, and Context what
%% the place of the call gives the code (PerformEval): `home` for super.x,
%% `new_target` in a function, `this_cell`, `class`, and `init` in a derived
%% constructor, `field` in a class field initializer, and `privates`, the
%% private names that the call sees as [{Name, Key}].
-spec direct(term(), list(), strict | sloppy, term(), [{binary(), term()}], [binary()], map()) -> term().
direct({'$f', {builtin, <<"eval">>}, _}, Args, Mode, This, Scope, Lexical, Context) ->
    case bouy_ref_realm:arg(1, Args) of
        Source when ?IS_STRING(Source) ->
            Privates = maps:get(privates, Context, []),
            Flags = mode_flag(Mode) ++ context_flags(Context)
                ++ names("--private=", [Name || {Name, _} <- Privates])
                ++ names("--scope=", [Name || {Name, _} <- Scope]) ++ names("--lexical=", Lexical),
            Keys = list_to_tuple([Key || {_, Key} <- Privates]),
            run(Source, Flags, This, Scope, Context#{privates => Keys});
        Value ->
            Value
    end;
direct(F, Args, _Mode, _This, _Scope, _Lexical, _Context) ->
    bouy_ref:call(F, undefined, Args).

mode_flag(strict) -> ["--strict"];
mode_flag(sloppy) -> [].

%% The place of the call (`bouy compile-eval --place`) that the keys of the
%% context map stand for.
context_flags(#{this_cell := _}) -> ["--place=constructor"];
context_flags(#{field := _}) -> ["--place=field"];
context_flags(#{home := _}) -> ["--place=method"];
context_flags(#{new_target := _}) -> ["--place=function"];
context_flags(#{}) -> [].

%% The variables that the sloppy eval code of a function declares: an object
%% without a prototype, which the function's code resolves names through.
-spec var_object() -> term().
var_object() -> bouy_heap:new_object(null).

%% EvalDeclarationInstantiation in a function's variables: each function
%% replaces the binding of its name, and each `var` name gets a binding that
%% holds undefined unless it exists. Eval code makes deletable bindings.
-spec declare_vars(term(), [binary()], [{binary(), term()}]) -> ok.
declare_vars(Vars, Names, Functions) ->
    lists:foreach(fun({Name, F}) -> declare_var(Vars, Name, F) end, Functions),
    lists:foreach(fun(Name) ->
                          case bouy_heap:has_own(Vars, Name) of
                              true -> ok;
                              false -> declare_var(Vars, Name, undefined)
                          end
                  end, Names).

declare_var(Vars, Name, Value) ->
    _ = bouy_heap:define(Vars, Name, #{value => Value, writable => true, enumerable => true, configurable => true}),
    ok.

%% A flag that lists names, or nothing for no names.
names(_Flag, []) -> [];
names(Flag, Names) -> [Flag ++ lists:join(",", [binary_to_list(bouy_ref_string:to_utf8(N)) || N <- Names])].

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
    run(Source, ["--function"], ?GLOBAL, [], #{}).

%% ScriptEvaluation for a host's evalScript, such as test262's
%% $262.evalScript: the source text as a classic script of its own in this
%% realm. Its top-level let, const, and class join the global declarative
%% record (bouy_ref_realm:declare_script/4).
-spec script(term()) -> term().
script(Source) ->
    Text = bouy_ref:to_string(Source),
    Flags = ["--script"],
    Key = erlang:md5(term_to_binary({Text, Flags})),
    Module = case cached(Key) of
        {ok, M} -> M;
        none -> compile(Text, Flags, Key)
    end,
    Module:'$body'().

%% Flags are the options of `bouy compile-eval`. A source text that is only
%% comments, or one regular expression literal, needs no module: programs
%% such as test262's character sweeps make tens of thousands of them.
run(Source, Flags, This, Scope, Context) ->
    case trivial(Source) of
        empty ->
            undefined;
        {regexp, Body, RegExpFlags} ->
            bouy_ref_regexp:literal(bouy_ref_string:from_units(Body), bouy_ref_string:to_utf8(bouy_ref_string:from_units(RegExpFlags)));
        code ->
            Key = erlang:md5(term_to_binary({Source, Flags})),
            Module = case cached(Key) of
                {ok, M} -> M;
                none -> compile(Source, [lists:flatten(Flag) || Flag <- Flags], Key)
            end,
            Module:'__eval__'(This, Scope, Context)
    end.

%% Starts the compiler process of the VM and waits for its first answer, so
%% that the start of the Bouy binary does not count against the first program
%% that evaluates code. Without BOUY_COMPILER it does nothing, and a compiler
%% that fails here fails again for the program, which reports it.
-spec warm_up() -> ok.
warm_up() ->
    Source = <<"0">>,
    try os:getenv("BOUY_COMPILER") =/= false andalso compile(Source, [], erlang:md5(term_to_binary({Source, []}))) of
        _ -> ok
    catch
        error:_ -> ok
    end.

%% The module of a source text and its flags, which the compiler process
%% records in its table once it has loaded it.
cached(Key) ->
    try ets:lookup(bouy_eval_modules, Key) of
        [{_, Module}] -> {ok, Module};
        [] -> none
    catch
        error:badarg -> none
    end.

%% Whether code units are only white space and comments (empty), one regular
%% expression literal ({regexp, Body, Flags}), or other code, which the
%% compiler checks. A hashbang comment may start the source text. A long
%% text goes to the compiler without the scan, which would copy it.
trivial(Source) ->
    case bouy_ref_string:length_of(Source) =< 4096 of
        true -> units_trivial(bouy_ref_string:units(Source));
        false -> code
    end.

units_trivial([$#, $! | Rest]) -> source_trivial([$/, $/ | Rest]);
units_trivial(Units) -> source_trivial(Units).

source_trivial([]) -> empty;
source_trivial([$/, $/ | Rest]) -> source_trivial(lists:dropwhile(fun(C) -> not line_terminator(C) end, Rest));
source_trivial([$/, $* | Rest]) -> block_comment(Rest);
source_trivial([$/ | Rest]) -> regexp(Rest, [], false);
source_trivial([C | Rest]) ->
    case bouy_ref_string:is_whitespace(C) of
        true -> source_trivial(Rest);
        false -> code
    end.

block_comment([$*, $/ | Rest]) -> source_trivial(Rest);
block_comment([_ | Rest]) -> block_comment(Rest);
block_comment([]) -> code.

%% The body of a regular expression literal, up to its closing slash outside
%% a class, then its flags, which must end the source text.
regexp([C | _], _Body, _Class) when C =:= 10; C =:= 13; C =:= 16#2028; C =:= 16#2029 -> code;
regexp([$\\, C | Rest], Body, Class) ->
    case line_terminator(C) of
        true -> code;
        false -> regexp(Rest, [C, $\\ | Body], Class)
    end;
regexp([$[ | Rest], Body, _Class) -> regexp(Rest, [$[ | Body], true);
regexp([$] | Rest], Body, true) -> regexp(Rest, [$] | Body], false);
regexp([$/ | Flags], Body, false) when Body =/= [] ->
    Valid = lists:all(fun(C) -> lists:member(C, "dgimsuvy") end, Flags)
        andalso length(lists:usort(Flags)) =:= length(Flags)
        andalso not (lists:member($u, Flags) andalso lists:member($v, Flags)),
    case Valid of
        true -> {regexp, lists:reverse(Body), Flags};
        false -> code
    end;
regexp([C | Rest], Body, Class) -> regexp(Rest, [C | Body], Class);
regexp([], _Body, _Class) -> code.

line_terminator(C) -> C =:= 10 orelse C =:= 13 orelse C =:= 16#2028 orelse C =:= 16#2029.

%% The compiler of the VM is one `bouy compile-eval --serve` process behind a
%% port, which a registered process owns, so that each eval costs a message
%% and not a new OS process. A request is the flags and the module name, one
%% on each line, then an empty line and the source text; an answer is a
%% status byte and the text. The server process also compiles and loads the
%% Erlang module, so the realm's heap and dictionary stay out of it.
compile(Source, Flags, Key) ->
    Name = "bouy_eval_" ++ integer_to_list(erlang:unique_integer([positive])),
    Request = [lists:join("\n", Flags ++ [Name]), "\n\n", bouy_ref_string:to_utf8(Source)],
    case call_compiler({Key, list_to_atom(Name)}, iolist_to_binary(Request)) of
        {module, Module} -> Module;
        {diagnostic, Diagnostic} -> report(Diagnostic);
        {failed, Output} -> type_error(bouy_ref_string:from_utf8(<<"the Bouy compiler failed: ", Output/binary>>))
    end.

call_compiler(Target, Request) ->
    Server = compiler(),
    Ref = erlang:monitor(process, Server),
    Server ! {compile, self(), Ref, Target, Request},
    receive
        {Ref, Answer} ->
            erlang:demonitor(Ref, [flush]),
            Answer;
        {'DOWN', Ref, process, _, Reason} ->
            type_error(bouy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("the Bouy compiler stopped: ~0tP", [Reason, 8]))))
    end.

%% The compiler process of the VM, started on first use.
compiler() ->
    case whereis(bouy_eval_compiler) of
        undefined -> start_compiler();
        Pid -> Pid
    end.

start_compiler() ->
    Compiler = case os:getenv("BOUY_COMPILER") of
        false -> type_error(<<"eval and new Function need the Bouy compiler: run the program with `bouy run`">>);
        C -> C
    end,
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        case try register(bouy_eval_compiler, self()) catch error:badarg -> false end of
            true ->
                bouy_eval_modules = ets:new(bouy_eval_modules, [named_table, public, {read_concurrency, true}]),
                Port = open_port({spawn_executable, Compiler}, [{args, ["compile-eval", "--serve"]}, {packet, 4}, binary, exit_status, use_stdio, hide]),
                Parent ! {self(), started},
                serve(Port);
            false ->
                Parent ! {self(), taken}
        end
    end),
    receive
        {Pid, started} -> erlang:demonitor(Ref, [flush]), Pid;
        {Pid, taken} -> erlang:demonitor(Ref, [flush]), compiler();
        {'DOWN', Ref, process, Pid, Reason} -> type_error(bouy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("the Bouy compiler did not start: ~0tP", [Reason, 8]))))
    end.

serve(Port) ->
    receive
        {compile, From, Ref, {Key, Module}, Request} ->
            true = port_command(Port, Request),
            Answer = receive
                {Port, {data, <<0, Erlang/binary>>}} -> load(Key, Module, Erlang);
                {Port, {data, <<2, Diagnostic/binary>>}} -> {diagnostic, Diagnostic};
                {Port, {data, <<_, Output/binary>>}} -> {failed, Output};
                {Port, {exit_status, Status}} -> exit({compiler_exit, Status})
            end,
            From ! {Ref, Answer},
            serve(Port);
        {Port, {exit_status, Status}} ->
            exit({compiler_exit, Status})
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

%% Eval code mostly runs once, so the module compiles without the optimizing
%% passes, in this process.
load(Key, Module, Erlang) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Erlang)),
    Forms = [Form || FormTokens <- split_forms(Tokens, [], []), {ok, Form} <- [erl_parse:parse_form(FormTokens)]],
    Options = [binary, return_errors, nowarn_unused_vars, nowarn_unused_function, no_spawn_compiler_process,
               no_ssa_opt, no_bool_opt, no_share_opt, no_recv_opt, no_postopt, no_type_opt, no_copt, no_bsm_opt,
               no_fun_opt, no_module_opt, no_line_info],
    case compile:forms(Forms, Options) of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
            true = ets:insert(bouy_eval_modules, {Key, Module}),
            {module, Module};
        Error ->
            {failed, unicode:characters_to_binary(io_lib:format("the Erlang compiler rejected eval code: ~0tP", [Error, 8]))}
    end.

split_forms([], [], Forms) -> lists:reverse(Forms);
split_forms([], Current, Forms) -> lists:reverse([lists:reverse(Current) | Forms]);
split_forms([{dot, _} = Dot | Rest], Current, Forms) -> split_forms(Rest, [], [lists:reverse([Dot | Current]) | Forms]);
split_forms([Token | Rest], Current, Forms) -> split_forms(Rest, [Token | Current], Forms).
