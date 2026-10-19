%% eval and the Function constructor: code that a program makes at run time.
%%
%% The runtime has no compiler of its own. It hands the source text to the
%% Buoy binary that BUOY_COMPILER names (`buoy compile-eval`), which prints an
%% Erlang module, and loads that module into the VM. The module's
%% '__eval__'/3 runs the code in the calling realm with a this, the scope of
%% the caller, and the context of the call, and returns its completion value.
%% A source text compiles once per VM for each list of flags.
%%
%% A sloppy function that calls eval directly gets an object for the `var`
%% names and functions that its eval code declares (var_object/0), which the
%% compiler treats as a `with` object around the function's body.
-module(buoy_ref_eval).

-include("buoy_ref.hrl").

-export([shadow_evaluate/2, source/1]).
-export([intrinsics/0, globals/0, method/4, direct/7, var_object/0, declare_vars/3, create_function/1, create_function/3, script/1, compile_script/1, warm_up/0, load_module/4, load_source/2]).

-import(buoy_ref, [type_error/1]).

-define(GLOBAL, buoy_ref_realm:global_object()).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"eval">>, eval_function()}].

eval_function() ->
    buoy_ref_realm:builtin(<<"eval">>, <<"eval">>, 1, fun(This, Args) -> ?MODULE:method(<<"globalThis">>, <<"eval">>, This, Args) end).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"globalThis">>, <<"eval">>, _This, Args) -> indirect(buoy_ref_realm:arg(1, Args)).

%% PerformEval of an indirect eval: global code, sloppy unless it says
%% otherwise.
indirect(Source) when ?IS_STRING(Source) -> run(Source, [], ?GLOBAL, [], #{});
indirect(Value) -> Value.

%% `eval(...)` where eval is the name of the global: a direct eval when it
%% still is the intrinsic, else a plain call.
%% Scope holds the caller's scope innermost first: [{Name, Cell}] for its
%% bindings (a copy for an immutable one, whose name starts with `!`, and
%% the cell of a `const`, whose name starts with `#`), with
%% {<<"@with">>, Object} for a `with` object and
%% {<<"@vars">>, Object} for the variables of a function. Lexical holds the
%% names that sloppy eval code may not declare with `var`, and Context what
%% the place of the call gives the code (PerformEval): `home` for super.x,
%% `new_target` in a function, `this_cell`, `class`, and `init` in a derived
%% constructor, `field` in a class field initializer, and `privates`, the
%% private names that the call sees as [{Name, Key}].
-spec direct(term(), list(), strict | sloppy, term(), [{binary(), term()}], [binary()], map()) -> term().
direct(F, Args, Mode, This, Scope, Lexical, Context) ->
    case is_eval(F, buoy_heap:realm()) of
        true -> direct_eval(Args, Mode, This, Scope, Lexical, Context);
        false -> buoy_ref:call(F, undefined, Args)
    end.

%% Whether F is %eval% of the realm N.
is_eval({'$f', {builtin, <<"eval">>}, _}, 0) -> true;
is_eval({'$f', {N, {builtin, <<"eval">>}}, _}, N) -> true;
is_eval(_F, _N) -> false.

direct_eval(Args, Mode, This, Scope, Lexical, Context) ->
    case buoy_ref_realm:arg(1, Args) of
        Source when ?IS_STRING(Source) ->
            Privates = maps:get(privates, Context, []),
            Flags = mode_flag(Mode) ++ context_flags(Context)
                ++ names("--private=", [Name || {Name, _} <- Privates])
                ++ names("--scope=", [Name || {Name, _} <- Scope]) ++ names("--lexical=", Lexical),
            Keys = list_to_tuple([Key || {_, Key} <- Privates]),
            run(Source, Flags, This, Scope, Context#{privates => Keys});
        Value ->
            Value
    end.

mode_flag(strict) -> ["--strict"];
mode_flag(sloppy) -> [].

%% The place of the call (`buoy compile-eval --place`) that the keys of the
%% context map stand for.
context_flags(#{this_cell := _}) -> ["--place=constructor"];
context_flags(#{field := _}) -> ["--place=field"];
context_flags(#{home := _}) -> ["--place=method"];
context_flags(#{new_target := _}) -> ["--place=function"];
context_flags(#{}) -> [].

%% The variables that the sloppy eval code of a function declares: an object
%% without a prototype, which the function's code resolves names through.
-spec var_object() -> term().
var_object() -> buoy_heap:new_object(null).

%% EvalDeclarationInstantiation in a function's variables: each function
%% replaces the binding of its name, and each `var` name gets a binding that
%% holds undefined unless it exists. Eval code makes deletable bindings.
-spec declare_vars(term(), [binary()], [{binary(), term()}]) -> ok.
declare_vars(Vars, Names, Functions) ->
    lists:foreach(fun({Name, F}) -> declare_var(Vars, Name, F) end, Functions),
    lists:foreach(fun(Name) ->
                          case buoy_heap:has_own(Vars, Name) of
                              true -> ok;
                              false -> declare_var(Vars, Name, undefined)
                          end
                  end, Names).

declare_var(Vars, Name, Value) ->
    _ = buoy_heap:define(Vars, Name, #{value => Value, writable => true, enumerable => true, configurable => true}),
    ok.

%% A flag that lists names, or nothing for no names.
names(_Flag, []) -> [];
names(Flag, Names) -> [Flag ++ lists:join(",", [binary_to_list(buoy_ref_string:to_utf8(N)) || N <- Names])].

%% CreateDynamicFunction: Function(p1, ..., body).
-spec create_function(list()) -> term().
create_function(Args) -> create_function(normal, Args, undefined).

%% CreateDynamicFunction of a kind: normal, generator, async, or
%% async_generator. The function gets its prototype from NewTarget, or from
%% the current realm for a call.
-spec create_function(normal | generator | async | async_generator, list(), term()) -> term().
create_function(Kind, Args, NewTarget) ->
    {Params, Body} = case Args of
        [] -> {[], <<>>};
        _ -> {lists:droplast(Args), lists:last(Args)}
    end,
    P = buoy_ref_string:concat(lists:join(<<",">>, [buoy_ref:to_string(A) || A <- Params])),
    B = buoy_ref:to_string(Body),
    Prefix = case Kind of
        normal -> <<"(function anonymous(">>;
        generator -> <<"(function* anonymous(">>;
        async -> <<"(async function anonymous(">>;
        async_generator -> <<"(async function* anonymous(">>
    end,
    Source = buoy_ref_string:concat([Prefix, P, <<"\n) {\n">>, B, <<"\n})">>]),
    %% The compiler checks that the parameter list ends after P, at the closing
    %% parenthesis that follows it, as the parameters must parse on their own.
    ParametersEnd = byte_size(buoy_ref_string:to_utf8(buoy_ref_string:concat(Prefix, P))) + 2,
    F = run(Source, ["--function=" ++ integer_to_list(ParametersEnd)], ?GLOBAL, [], #{}),
    case NewTarget of
        undefined -> F;
        _ -> buoy_heap:set_prototype_of(F, buoy_ref_realm:proto_for(NewTarget, kind_prototype(Kind)))
    end.

kind_prototype(normal) -> 'Function.prototype';
kind_prototype(Kind) -> buoy_ref_function:kind_prototype_id(Kind).

%% ScriptEvaluation for a host's evalScript, such as test262's
%% $262.evalScript: the source text as a classic script of its own in this
%% realm. Its top-level let, const, and class join the global declarative
%% record (buoy_ref_realm:declare_script/4).
-spec script(term()) -> term().
script(Source) ->
    (compile_script(Source)):'$body'().

%% The module of a classic script, which '$body'/0 evaluates; a SyntaxError
%% of the source throws here, as vm.Script compiles before it runs.
-spec compile_script(term()) -> module().
compile_script(Source) ->
    Text = buoy_ref:to_string(Source),
    Flags = ["--script"],
    Key = erlang:md5(term_to_binary({Text, Flags})),
    case cached(Key) of
        {ok, M} -> M;
        none -> compile(Text, Flags, Key)
    end.

%% Flags are the options of `buoy compile-eval`. A source text that is only
%% comments, or one regular expression literal, needs no module: programs
%% such as test262's character sweeps make tens of thousands of them.
run(Source, Flags0, This, Scope, Context) ->
    %% The functions of eval code record their calls when the program does.
    Flags = case erlang:get('$buoy_frames') of
        undefined -> Flags0;
        _ -> ["--frames" | Flags0]
    end,
    case trivial(Source) of
        empty ->
            undefined;
        {regexp, Body, RegExpFlags} ->
            buoy_ref_regexp:literal(buoy_ref_string:from_units(Body), buoy_ref_string:to_utf8(buoy_ref_string:from_units(RegExpFlags)));
        code ->
            Key = erlang:md5(term_to_binary({Source, Flags})),
            Module = case cached(Key) of
                {ok, M} -> M;
                none -> compile(Source, [lists:flatten(Flag) || Flag <- Flags], Key)
            end,
            Module:'__eval__'(This, Scope, Context)
    end.

%% PerformShadowRealmEval: the code compiles where evaluate runs, so that a
%% syntax error throws in the caller's realm, and runs as an indirect eval in
%% the realm N. An error of the code comes back as {error, Value}.
-spec shadow_evaluate(term(), pos_integer()) -> {ok, term()} | {error, term()}.
shadow_evaluate(Source, N) ->
    Code = case trivial(Source) of
        empty ->
            fun() -> undefined end;
        {regexp, Body, RegExpFlags} ->
            fun() -> buoy_ref_regexp:literal(buoy_ref_string:from_units(Body), buoy_ref_string:to_utf8(buoy_ref_string:from_units(RegExpFlags))) end;
        code ->
            Key = erlang:md5(term_to_binary({Source, []})),
            Module = case cached(Key) of
                {ok, M} -> M;
                none -> compile(Source, [], Key)
            end,
            fun() -> Module:'__eval__'(?GLOBAL, [], #{}) end
    end,
    Run = buoy_ref_realm:realm_fun(N, fun(_, _) ->
                                              try {ok, Code()}
                                              catch error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
                                              end
                                      end),
    Run(undefined, undefined).

%% Starts the compiler process of the VM and waits for its first answer, so
%% that the start of the Buoy binary does not count against the first program
%% that evaluates code. Without BUOY_COMPILER it does nothing, and a compiler
%% that fails here fails again for the program, which reports it.
-spec warm_up() -> ok.
warm_up() ->
    Source = <<"0">>,
    try os:getenv("BUOY_COMPILER") =/= false andalso compile(Source, [], erlang:md5(term_to_binary({Source, []}))) of
        _ -> ok
    catch
        error:_ -> ok
    end.

%% The module of a source text and its flags, which the compiler process
%% records in its table once it has loaded it.
cached(Key) ->
    try ets:lookup(buoy_eval_modules, Key) of
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
    case buoy_ref_string:length_of(Source) =< 4096 of
        true -> units_trivial(buoy_ref_string:units(Source));
        false -> code
    end.

units_trivial([$#, $! | Rest]) -> source_trivial([$/, $/ | Rest]);
units_trivial(Units) -> source_trivial(Units).

source_trivial([]) -> empty;
source_trivial([$/, $/ | Rest]) -> source_trivial(lists:dropwhile(fun(C) -> not line_terminator(C) end, Rest));
source_trivial([$/, $* | Rest]) -> block_comment(Rest);
source_trivial([$/ | Rest]) -> regexp(Rest, [], false);
source_trivial([C | Rest]) ->
    case buoy_ref_string:is_whitespace(C) of
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

%% The compiler of the VM is one `buoy compile-eval --serve` process behind a
%% port, which a registered process owns, so that each eval costs a message
%% and not a new OS process. A request is the flags and the module name, one
%% on each line, then an empty line and the source text; an answer is a
%% status byte and the text. The server only turns source text into Erlang;
%% a process of the caller's own compiles and loads that Erlang, so evals of
%% several realms compile at once, and the realm's heap and dictionary stay
%% out of it. The name of each module is unique, so two realms that compile
%% the same text at once load two modules, and the table keeps either.
compile(Source, Flags, Key) ->
    Name = "buoy_eval_" ++ integer_to_list(erlang:unique_integer([positive])),
    Request = [lists:join("\n", Flags ++ [Name]), "\n\n", buoy_ref_string:to_utf8(Source)],
    case call_compiler(iolist_to_binary(Request)) of
        <<0, Size:32, Erlang:Size/binary, Text/binary>> ->
            Module = list_to_atom(Name),
            true = ets:insert(buoy_eval_modules, {Module, Text}),
            loaded(load_apart(Key, Module, Erlang));
        <<2, Diagnostic/binary>> -> report(Diagnostic);
        <<_, Output/binary>> -> loaded({failed, Output})
    end.

loaded({module, Module}) -> Module;
loaded({failed, Output}) -> type_error(buoy_ref_string:from_utf8(<<"the Buoy compiler failed: ", Output/binary>>)).

call_compiler(Request) ->
    Server = compiler(),
    Ref = erlang:monitor(process, Server),
    Server ! {raw, self(), Ref, Request},
    receive
        {Ref, {answer, Answer}} ->
            erlang:demonitor(Ref, [flush]),
            Answer;
        {'DOWN', Ref, process, _, Reason} ->
            type_error(buoy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("the Buoy compiler stopped: ~0tP", [Reason, 8]))))
    end.

%% The source text of the eval module Module, which its '$source'/0 reads: the
%% compiler sends it beside the module, so the VM never scans it as a literal.
-spec source(module()) -> binary().
source(Module) ->
    [{_, Text}] = ets:lookup(buoy_eval_modules, Module),
    Text.

%% load/3 in a process linked to the caller, which a timeout or a kill of the
%% caller stops too.
load_apart(Key, Module, Erlang) ->
    Caller = self(),
    {Pid, Ref} = spawn_opt(fun() ->
                                   Result = try load(Key, Module, Erlang)
                                            catch Class:Reason -> {failed, unicode:characters_to_binary(io_lib:format("~p: ~0tP", [Class, Reason, 8]))}
                                            end,
                                   Caller ! {self(), Result}
                           end, [link, monitor]),
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            {failed, unicode:characters_to_binary(io_lib:format("the Erlang compiler stopped: ~0tP", [Reason, 8]))}
    end.

%% The compiler process of the VM, started on first use.
compiler() ->
    case whereis(buoy_eval_compiler) of
        undefined -> start_compiler();
        Pid -> Pid
    end.

start_compiler() ->
    Compiler = case os:getenv("BUOY_COMPILER") of
        false -> type_error(<<"eval and new Function need the Buoy compiler: run the program with `buoy run`">>);
        C -> C
    end,
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        case try register(buoy_eval_compiler, self()) catch error:badarg -> false end of
            true ->
                buoy_eval_modules = ets:new(buoy_eval_modules, [named_table, public, {read_concurrency, true}]),
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
        {'DOWN', Ref, process, Pid, Reason} -> type_error(buoy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("the Buoy compiler did not start: ~0tP", [Reason, 8]))))
    end.

serve(Port) ->
    receive
        {raw, From, Ref, Request} ->
            true = port_command(Port, Request),
            Answer = receive
                {Port, {data, Data}} -> Data;
                {Port, {exit_status, Status}} -> exit({compiler_exit, Status})
            end,
            From ! {Ref, {answer, Answer}},
            serve(Port);
        {load, From, Ref, Module, Binary} ->
            case code:is_loaded(Module) of
                false -> {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary);
                _ -> ok
            end,
            From ! {Ref, ok},
            serve(Port);
        {Port, {exit_status, Status}} ->
            exit({compiler_exit, Status})
    end.

%% A module that a running program loads at run time (buoy_module): the
%% compiler resolves Specifier from the file Importer and compiles the target's
%% program in the project of Main. The modules that the VM does not hold yet
%% load here. The result is {program, Path, Module, Graph}, {builtin, Name},
%% or {error, Code, Message}.
-spec load_module(binary(), binary(), binary(), require | import) -> term().
load_module(Main, Importer, Specifier, Mode) ->
    loaded_program(ask(iolist_to_binary(["@load\n", Main, "\n", Importer, "\n", Specifier, "\n", atom_to_list(Mode), "\n\n"]))).

%% The program whose entry is the source text Source at Path, such as the
%% code of a worker that eval: true starts, as load_module/4 returns it.
-spec load_source(binary(), binary()) -> term().
load_source(Path, Source) ->
    loaded_program(ask(iolist_to_binary(["@source\n", Path, "\n\n", Source]))).

ask(Request) ->
    Server = compiler(),
    Ref = erlang:monitor(process, Server),
    Server ! {raw, self(), Ref, Request},
    receive
        {Ref, {answer, A}} -> erlang:demonitor(Ref, [flush]), A;
        {'DOWN', Ref, process, _, Reason} -> exit({compiler_down, Reason})
    end.

loaded_program(Answer) ->
    case Answer of
        <<0, "builtin\n", Name/binary>> ->
            {builtin, Name};
        <<0, "program\n", Rest/binary>> ->
            [Path, Modules] = binary:split(Rest, <<"\n">>),
            Loaded = load_modules(Modules, []),
            [{Entry, _} | _] = Loaded,
            %% The answer names every module of the program, also one that the
            %% VM loaded before as a module of another program, without '$graph'/0.
            {program, Path, Entry, [{buoy_ref_string:from_utf8(P), M} || {M, P} <- Loaded]};
        <<2, Diagnostic/binary>> ->
            case binary:split(Diagnostic, <<"\t">>) of
                [Code, Message] -> {error, Code, Message};
                [Message] -> {error, <<"MODULE_NOT_FOUND">>, Message}
            end;
        <<_, Output/binary>> ->
            {error, <<"ERR_BUOY_COMPILE">>, Output}
    end.

load_modules(<<>>, Acc) ->
    lists:reverse(Acc);
load_modules(Text, Acc) ->
    [Name, Path, Size, Rest] = split3(Text),
    Length = binary_to_integer(Size),
    <<Erlang:Length/binary, More/binary>> = Rest,
    Module = binary_to_atom(Name),
    case code:is_loaded(Module) of
        false -> ok = load_once(Module, compile_loaded(Erlang));
        _ -> ok
    end,
    load_modules(More, [{Module, Path} | Acc]).

split3(Text) ->
    [Name, R1] = binary:split(Text, <<"\n">>),
    [Path, R2] = binary:split(R1, <<"\n">>),
    [Size, Rest] = binary:split(R2, <<"\n">>),
    [Name, Path, Size, Rest].

%% A module of a loaded program compiles in this process, without the
%% optimizing passes, as eval code does.
compile_loaded(Erlang) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Erlang)),
    Forms = [Form || FormTokens <- split_forms(Tokens, [], []), {ok, Form} <- [erl_parse:parse_form(FormTokens)]],
    Options = [binary, from_abstr, no_lint, nowarn_unused_vars, nowarn_unused_function, no_spawn_compiler_process,
               no_ssa_opt, no_bool_opt, no_share_opt, no_recv_opt, no_postopt, no_type_opt, no_copt, no_bsm_opt,
               no_fun_opt, no_module_opt, no_line_info],
    {ok, _Module, Binary} = compile:forms(Forms, Options),
    Binary.

%% The compiler process loads each module once: realms that load the same
%% module at once, such as workers that start the same script, would
%% otherwise load it twice, and the second load purges the code that the
%% first realm runs, which kills that realm.
load_once(Module, Binary) ->
    Server = compiler(),
    Ref = erlang:monitor(process, Server),
    Server ! {load, self(), Ref, Module, Binary},
    receive
        {Ref, ok} -> erlang:demonitor(Ref, [flush]), ok;
        {'DOWN', Ref, process, _, Reason} -> exit({compiler_down, Reason})
    end.

%% The compiler reports a diagnostic as <ErrorName>\t<message>.
-spec report(binary()) -> no_return().
report(Output) ->
    {Name, Message} = case binary:split(Output, <<"\t">>) of
        [<<"SyntaxError">>, M] -> {'SyntaxError', M};
        [_, M] -> {'TypeError', M};
        [M] -> {'TypeError', M}
    end,
    buoy_heap:throw_error(Name, buoy_ref_string:from_utf8(Message)).

%% Eval code mostly runs once, so the module compiles without the optimizing
%% passes, in this process. It also skips erl_lint (no_lint), which the Buoy
%% compiler's output does not need and which takes time quadratic in the funs
%% of one function: 1000 methods in one object literal took minutes.
load(Key, Module, Erlang) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Erlang)),
    Forms = [Form || FormTokens <- split_forms(Tokens, [], []), {ok, Form} <- [erl_parse:parse_form(FormTokens)]],
    Options = [binary, return_errors, from_abstr, no_lint, nowarn_unused_vars, nowarn_unused_function,
               no_spawn_compiler_process, no_ssa_opt, no_bool_opt, no_share_opt, no_recv_opt, no_postopt,
               no_type_opt, no_copt, no_bsm_opt, no_fun_opt, no_module_opt, no_line_info],
    case compile:forms(Forms, Options) of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
            true = ets:insert(buoy_eval_modules, {Key, Module}),
            {module, Module};
        Error ->
            {failed, unicode:characters_to_binary(io_lib:format("the Erlang compiler rejected eval code: ~0tP", [Error, 8]))}
    end.

split_forms([], [], Forms) -> lists:reverse(Forms);
split_forms([], Current, Forms) -> lists:reverse([lists:reverse(Current) | Forms]);
split_forms([{dot, _} = Dot | Rest], Current, Forms) -> split_forms(Rest, [], [lists:reverse([Dot | Current]) | Forms]);
split_forms([Token | Rest], Current, Forms) -> split_forms(Rest, [Token | Current], Forms).
