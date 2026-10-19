-module(buoy_build).

%% Compiles the modules of a program when the program first needs them (section 1 of
%% docs/design/beam-runtime.md).
%%
%% The CLI writes the Erlang source of each module that the program can reach to
%% <build dir>/src. start/3 compiles the entry, and ensure/1 compiles any other module
%% at the first import or require that reaches it, so a module that the program never
%% loads costs nothing: the static graph of a package holds every file that a literal
%% `require` names, also in branches that never run. Once a module is ready, the
%% modules that it imports or requires by a literal specifier compile ahead, up to
%% eight at a time, so a graph of many modules compiles in parallel. Each compiled
%% module goes to <build dir>/ebin with an MD5 stamp of its source, and a later run
%% loads it from there.

-export([start/3, ensure/1, compile_generated/2]).

-include_lib("kernel/include/file.hrl").

%% The state of each module of the program: `pending` until a compilation starts,
%% `{compiling, Waiters}` during it, and `ready` after it.
-record(state, {build, ebin, entry, modules = #{}, queue = queue:new(), workers = #{}, jobs}).

%% Starts the build server of the program in Build, whose modules are Modules, and
%% compiles the entry. An error of the entry is an error of the whole program.
-spec start(file:filename(), module(), [module()]) -> ok | {error, [unicode:chardata()]}.
start(Build, Entry, Modules) ->
    Ebin = filename:join(Build, "ebin"),
    case file:make_dir(Ebin) of
        ok -> ok;
        {error, eexist} -> ok;
        {error, Reason} -> buoy_main:stop(1, io_lib:format("buoy: cannot write ~ts: ~ts~n", [Ebin, file:format_error(Reason)]))
    end,
    true = code:add_patha(Ebin),
    case compile(Build, Ebin, Entry, Entry) of
        [] ->
            State = #state{build = Build, ebin = Ebin, entry = Entry,
                           modules = maps:from_keys(Modules -- [Entry], pending),
                           jobs = max(1, min(8, erlang:system_info(schedulers_online)))},
            Server = spawn(fun() -> serve(prefetch(next(Entry), State)) end),
            true = register(?MODULE, Server),
            ok;
        Errors ->
            {error, Errors}
    end.

%% Loads Module. A module of the program compiles first, unless a compilation is under
%% way, which this waits for, or done.
-spec ensure(module()) -> ok.
ensure(Module) ->
    case erlang:module_loaded(Module) orelse whereis(?MODULE) of
        true ->
            ok;
        undefined ->
            _ = code:ensure_loaded(Module),
            ok;
        Server ->
            Ref = erlang:monitor(process, Server),
            Server ! {ensure, Module, self(), Ref},
            receive
                {Ref, ready} -> erlang:demonitor(Ref, [flush]);
                {'DOWN', Ref, process, _, _} -> ok
            end,
            _ = code:ensure_loaded(Module),
            ok
    end.

serve(State) ->
    receive
        {ensure, Module, From, Ref} ->
            serve(demand(Module, {From, Ref}, State));
        {'DOWN', Ref, process, _, Reason} ->
            serve(finish(Ref, Reason, State))
    end.

demand(Module, Waiter, #state{modules = Modules} = State) ->
    case maps:get(Module, Modules, ready) of
        ready ->
            reply([Waiter]),
            State;
        {compiling, Waiters} ->
            State#state{modules = Modules#{Module := {compiling, [Waiter | Waiters]}}};
        pending ->
            launch(Module, [Waiter], State)
    end.

%% Queues the modules that a ready module loads by literal specifiers, and starts as many
%% compilations as the jobs allow.
prefetch(Next, #state{modules = Modules, queue = Queue} = State) ->
    Queued = lists:foldl(fun queue:in/2, Queue, [M || M <- Next, maps:get(M, Modules, ready) =:= pending]),
    fill(State#state{queue = Queued}).

fill(#state{workers = Workers, jobs = Jobs} = State) when map_size(Workers) >= Jobs ->
    State;
fill(#state{queue = Queue, modules = Modules} = State) ->
    case queue:out(Queue) of
        {empty, _} -> State;
        {{value, Module}, Rest} when map_get(Module, Modules) =:= pending -> fill(launch(Module, [], State#state{queue = Rest}));
        {{value, _}, Rest} -> fill(State#state{queue = Rest})
    end.

launch(Module, Waiters, #state{build = Build, ebin = Ebin, entry = Entry, modules = Modules, workers = Workers} = State) ->
    {_, Ref} = spawn_monitor(fun() -> exit({compiled, compile(Build, Ebin, Entry, Module)}) end),
    State#state{modules = Modules#{Module := {compiling, Waiters}}, workers = Workers#{Ref => Module}}.

%% A module that does not compile, of the value semantics, ends the program as at boot.
finish(Ref, Reason, #state{modules = Modules, workers = Workers} = State) ->
    {Module, Rest} = maps:take(Ref, Workers),
    case Reason of
        {compiled, []} ->
            {compiling, Waiters} = map_get(Module, Modules),
            reply(Waiters),
            prefetch(next(Module), State#state{modules = Modules#{Module := ready}, workers = Rest});
        {compiled, Errors} ->
            buoy_main:stop(2, Errors);
        _ ->
            buoy_main:stop(2, io_lib:format("buoy: compiling ~ts failed: ~tp~n", [Module, Reason]))
    end.

reply(Waiters) ->
    lists:foreach(fun({From, Ref}) -> From ! {Ref, ready} end, Waiters).

%% The modules that Module imports, and the ones that it requires by literal specifiers.
next(Module) ->
    case erlang:function_exported(Module, '$module', 0) of
        true ->
            Info = Module:'$module'(),
            [unphase(R) || R <- maps:get(requests, Info, []) ++ maps:get(requires, Info, [])];
        false ->
            []
    end.

unphase({_, R}) -> R;
unphase(R) -> R.

%% Compiles Module when its source changed since the last build, and loads it. A module
%% other than the entry that does not compile becomes a module that throws when the
%% program loads it.
compile(Build, Ebin, Entry, Module) ->
    Name = atom_to_list(Module),
    Source = filename:join([Build, "src", Name ++ ".erl"]),
    Beam = filename:join(Ebin, Name ++ ".beam"),
    Stamp = filename:join(Ebin, Name ++ ".md5"),
    {ok, Text} = file:read_file(Source),
    Hash = erlang:md5([Text, erlang:system_info(otp_release)]),
    Fresh = file:read_file(Stamp) =:= {ok, Hash} andalso file:read_file(Beam),
    case Fresh of
        {ok, Binary} -> load(Module, Beam, Binary);
        _ -> compile_source(Source, Beam, Stamp, Hash, Module =:= Entry)
    end.

compile_source(Source, Beam, Stamp, Hash, IsEntry) ->
    Compiled = compile_generated(Source, [binary, return_errors, nowarn_unused_vars]),
    case {Compiled, IsEntry} of
        {{ok, _, _}, _} -> store(Compiled, Beam, Stamp, Hash);
        {_, true} -> compile_errors(Source, Compiled);
        {_, false} -> store(broken_module(Source, compile_errors(Source, Compiled)), Beam, Stamp, Hash)
    end.

store({ok, Module, Binary}, Beam, Stamp, Hash) ->
    ok = replace(Beam, Binary),
    ok = replace(Stamp, Hash),
    load(Module, Beam, Binary);
store({error, Errors}, _Beam, _Stamp, _Hash) ->
    Errors.

%% A dynamic `require` that the running program compiles (buoy_ref_eval) can load the
%% module first.
load(Module, Beam, Binary) ->
    case erlang:module_loaded(Module) of
        true -> [];
        false -> {module, Module} = code:load_binary(Module, Beam, Binary), []
    end.

compile_errors(_Source, {error, Errors, _Warnings}) ->
    [format_error(File, Error) || {File, FileErrors} <- Errors, Error <- FileErrors];
compile_errors(Source, _) ->
    [io_lib:format("buoy: the Erlang compiler crashed on ~ts (a compiler bug)~n", [Source])].

%% compile:file/2 for a module that the Buoy compiler wrote. Such code needs no
%% erl_lint, whose time grows with the square of the funs of one function, so
%% the module compiles from its forms without it. A form that does not parse
%% goes to compile:file/2, which reports it.
-spec compile_generated(file:filename(), [term()]) -> term().
compile_generated(Source, Options) ->
    case epp:parse_file(Source, []) of
        {ok, Forms} ->
            case lists:keymember(error, 1, Forms) of
                false -> compile:forms(Forms, [from_abstr, no_lint, {source, Source} | Options]);
                true -> compile:file(Source, Options)
            end;
        {error, _} ->
            compile:file(Source, Options)
    end.

%% The module of a dependency whose generated Erlang does not compile: the import or
%% require that reaches it throws the error, as Node throws for a module that fails to
%% load, and the other modules run. It has the functions of a module with a compile
%% diagnostic (broken_functions in crates/buoy-compiler/src/reference/linking.rs). A
%% module without '$module'/0, of the value semantics, stays an error of the program.
-spec broken_module(file:filename(), [unicode:chardata()]) -> {ok, module(), binary()} | {error, [unicode:chardata()]}.
broken_module(Source, Errors) ->
    Forms = case epp:parse_file(Source, []) of
        {ok, Parsed} -> Parsed;
        {error, _} -> []
    end,
    case {[M || {attribute, _, module, M} <- Forms], [F || {function, _, '$module', 0, _} = F <- Forms]} of
        {[Module], [{function, A, _, _, [{clause, CA, [], [], [{map, MA, Fields}]}]}]} ->
            Message = buoy_ref_string:from_utf8(unicode:characters_to_binary(string:trim(Errors))),
            Error = erl_parse:abstract({<<"Error">>, <<"ERR_BUOY_COMPILE">>, Message}, [{line, A}]),
            Info = [case Key of
                        error -> {map_field_assoc, FA, K, Error};
                        loaded -> {map_field_assoc, FA, K, {atom, FA, false}};
                        _ -> Field
                    end || {map_field_assoc, FA, {atom, _, Key} = K, _} = Field <- Fields],
            Broken = [{call, A, {remote, A, {atom, A, buoy_module}, {atom, A, broken}}, [{atom, A, Module}]}],
            Resolve = [F || {function, _, '$resolve', 2, _} = F <- Forms],
            Functions = [{function, A, '$module', 0, [{clause, CA, [], [], [{map, MA, Info}]}]},
                         {function, A, '$namespace', 0, [{clause, A, [], [], [{nil, A}]}]},
                         {function, A, '$body', 0, [{clause, A, [], [], Broken}]},
                         {function, A, '$cjs', 0, [{clause, A, [], [], Broken}]},
                         {function, A, '$json', 0, [{clause, A, [], [], Broken}]},
                         {function, A, '$export', 1, [{clause, A, [{var, A, '_'}], [], Broken}]}
                         | Resolve],
            Exports = [{Name, Arity} || {function, _, Name, Arity, _} <- Functions],
            case compile:forms([{attribute, A, module, Module}, {attribute, A, export, Exports} | Functions],
                               [binary, return_errors]) of
                {ok, Module, Binary} -> {ok, Module, Binary};
                _ -> {error, Errors}
            end;
        _ ->
            {error, Errors}
    end.

%% Writes File through a temporary file and a rename, so a concurrent reader never sees
%% a partial file.
replace(File, Contents) ->
    Temporary = File ++ "." ++ os:getpid(),
    ok = file:write_file(Temporary, Contents),
    file:rename(Temporary, File).

format_error(File, {Location, Module, Descriptor}) ->
    io_lib:format("buoy: generated Erlang does not compile (a compiler bug): ~ts:~w: ~ts~n",
                  [File, line(Location), Module:format_error(Descriptor)]).

line({Line, _Column}) -> Line;
line(Line) -> Line.
