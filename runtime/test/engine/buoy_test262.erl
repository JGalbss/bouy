%% The VM half of the test262 development runner (crates/buoy-cli/src/bin/test262-dev.rs):
%% one VM runs many compiled tests, each in a realm process of its own, so a test does
%% not pay for the start of a VM.
%%
%%   erl ... -pa <runtime ebin> -pa <dir of this module> -eval 'buoy_test262:main()'
%%       -extra <manifest> <jobs> <output dir>
%%
%% Each line of the manifest is "<index>\t<erl file>,...\t<timeout ms>": the entry module
%% of the test, then the modules it imports. For each test, the runner prints
%% "START <index>", loads the imported modules once per VM (tests share fixtures), compiles
%% and loads the entry module, runs it with stdout and stderr captured into
%% <output dir>/<index>.out and .err, and prints "DONE <index> <status>": the exit status,
%% timeout, memory, or compile.
-module(buoy_test262).

-export([main/0]).

%% A realm that grows past this many words (256 MB), counting the large binaries it
%% holds, ends with the outcome `memory`. buoy_guard caps the whole VM.
-define(MAX_HEAP_WORDS, 32 * 1024 * 1024).
%% An agent of $262.agent (64 MB). Agents link to their test, so an agent past it ends
%% the test with the outcome `memory` too.
-define(AGENT_HEAP_WORDS, 8 * 1024 * 1024).
-define(OBJECT_PROTO, {'$o', 'Object.prototype'}).

-import(buoy_ref_realm, [arg/2]).

-spec main() -> no_return().
main() ->
    ok = buoy_guard:start(),
    [Manifest, Jobs, Out] = init:get_plain_arguments(),
    {ok, Text} = file:read_file(Manifest),
    Tests = list_to_tuple([parse(Line) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])]),
    {ok, Runtime} = buoy_app:start(normal, []),
    true = unlink(Runtime),
    ok = buoy_ref_eval:warm_up(),
    Next = atomics:new(1, []),
    Loader = spawn(fun() -> loader(#{}) end),
    Workers = [spawn_monitor(fun() -> worker(Tests, Next, Out, Loader) end) || _ <- lists:seq(1, list_to_integer(Jobs))],
    [receive {'DOWN', Ref, process, Pid, _} -> ok end || {Pid, Ref} <- Workers],
    erlang:halt(0).

parse(Line) ->
    [Index, Files, Timeout] = binary:split(Line, <<"\t">>, [global]),
    [File | Imports] = [binary_to_list(F) || F <- binary:split(Files, <<",">>, [global])],
    {Index, File, Imports, binary_to_integer(Timeout)}.

worker(Tests, Next, Out, Loader) ->
    I = atomics:add_get(Next, 1, 1),
    case I =< tuple_size(Tests) of
        true ->
            run(element(I, Tests), Out, Loader),
            worker(Tests, Next, Out, Loader);
        false ->
            ok
    end.

%% Loads the modules of the tests. A module loads once: tests share fixtures, a test may
%% import another test, and a second load of a module in use would purge the code that a
%% realm runs. Each test holds its modules. The module of a test is released when the
%% test ends, and purged when no test holds it and no test imports it; an imported module
%% stays loaded. The workers compile, so the loader only loads.
loader(Held) ->
    receive
        {loaded, File, From} ->
            From ! {loaded, File, maps:find(File, Held)},
            loader(Held);
        {load, File, Module, Binary, Entry, From} ->
            Held1 = case Held of
                #{File := {Known, Count, Transient}} ->
                    Held#{File => {Known, Count + 1, Transient andalso Entry}};
                _ ->
                    {module, Module} = code:load_binary(Module, File, Binary),
                    Held#{File => {Module, 1, Entry}}
            end,
            {Loaded, _, _} = maps:get(File, Held1),
            From ! {held, File, Loaded},
            loader(Held1);
        {release, File} ->
            case Held of
                #{File := {Module, 1, true}} ->
                    _ = code:purge(Module),
                    _ = code:delete(Module),
                    _ = code:purge(Module),
                    loader(maps:remove(File, Held));
                #{File := {Module, Count, Transient}} ->
                    loader(Held#{File => {Module, Count - 1, Transient}});
                _ ->
                    loader(Held)
            end
    end.

%% Holds a module for a test: compiled here unless the loader has it already.
hold(File, Entry, Loader) ->
    Loader ! {loaded, File, self()},
    Compiled = receive
        {loaded, File, {ok, {Module, _, _}}} -> {ok, Module, none};
        {loaded, File, error} -> buoy_build:compile_generated(File, [binary, return_errors, nowarn_unused_vars])
    end,
    case Compiled of
        {ok, Name, Binary} ->
            Loader ! {load, File, Name, Binary, Entry, self()},
            receive {held, File, Loaded} -> {ok, Loaded} end;
        Failed ->
            {error, Failed}
    end.

run({Index, File, Imports, Timeout}, Out, Loader) ->
    io:format("START ~ts~n", [Index]),
    Base = filename:join(Out, binary_to_list(Index)),
    Held = lists:foldl(fun(Import, ok) ->
                               case hold(Import, false, Loader) of
                                   {ok, _} -> ok;
                                   {error, Failed} -> {import, Failed}
                               end;
                          (_, Failed) ->
                               Failed
                       end, ok, Imports),
    Status = case Held =:= ok andalso hold(File, true, Loader) of
        {ok, Module} ->
            Result = execute(Module, Timeout, Base),
            Loader ! {release, File},
            Result;
        {error, Failed} ->
            ok = file:write_file(Base ++ ".err", io_lib:format("the Erlang compiler rejected the module: ~0tP~n", [Failed, 12])),
            ok = file:write_file(Base ++ ".out", <<>>),
            "compile";
        false ->
            {import, Rejected} = Held,
            ok = file:write_file(Base ++ ".err", io_lib:format("the Erlang compiler rejected an imported module: ~0tP~n", [Rejected, 12])),
            ok = file:write_file(Base ++ ".out", <<>>),
            "compile"
    end,
    io:format("DONE ~ts ~ts~n", [Index, Status]).

%% Runs the top-level code in a new process, with its output captured.
execute(Module, Timeout, Base) ->
    Stdout = capture(),
    Stderr = capture(),
    {Pid, Ref} = spawn_opt(fun() -> realm(Module, Stdout, Stderr) end,
                           [monitor, {max_heap_size, #{size => ?MAX_HEAP_WORDS, kill => true, error_logger => false, include_shared_binaries => true}}]),
    Status = receive
        {'DOWN', Ref, process, Pid, {'$buoy_exit', Code}} -> integer_to_list(Code);
        {'DOWN', Ref, process, Pid, killed} -> "memory";
        {'DOWN', Ref, process, Pid, Reason} ->
            io:put_chars(Stderr, io_lib:format("the realm crashed: ~0tP~n", [Reason, 12])),
            "1"
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end,
        "timeout"
    end,
    ok = file:write_file(Base ++ ".out", collect(Stdout)),
    ok = file:write_file(Base ++ ".err", collect(Stderr)),
    Status.

realm(Module, Stdout, Stderr) ->
    group_leader(Stdout, self()),
    erlang:put('$buoy_exit', true),
    erlang:put('$buoy_stderr', Stderr),
    erlang:put('$buoy_rejections', ignore),
    host_functions(),
    define_host(main_agent()),
    try Module:'__init__'() of
        _ -> exit({'$buoy_exit', 0})
    catch
        exit:{'$buoy_exit', _} = Exit ->
            exit(Exit);
        Class:Reason:Stack ->
            io:put_chars(Stderr, io_lib:format("Uncaught ~p: ~0tP ~0tP~n", [Class, Reason, 12, Stack, 12])),
            exit({'$buoy_exit', 1})
    end.

%% The host functions of $262 that only the engine can give, as hidden
%% globals that the host code of the runner (HOST in test262-dev.rs) wraps:
%% $262CreateRealm, which the prelude takes off the global object, and
%% __buoyEvalScript and __buoyAbstractModuleSource, which each realm has.
host_functions() ->
    ok = buoy_ref:init_realm(),
    G = buoy_ref_realm:global_object(),
    define_hidden(G, <<"$262CreateRealm">>, buoy_ref_realm:builtin(<<"$262.createRealm">>, fun(_This, _Args) -> create_realm() end)),
    define_hidden(G, <<"__buoyEvalScript">>, eval_script()),
    define_hidden(G, <<"__buoyAbstractModuleSource">>, buoy_ref_module_source:constructor()).

%% A realm of $262.createRealm: its global object, with an evalScript that
%% runs in that realm.
create_realm() ->
    {'$o', {N, _}} = G = buoy_ref_realm:create(),
    define_hidden(G, <<"__buoyEvalScript">>, buoy_ref_realm:localize(N, eval_script())),
    define_hidden(G, <<"__buoyAbstractModuleSource">>, buoy_ref_realm:localize(N, buoy_ref_module_source:constructor())),
    G.

eval_script() ->
    buoy_ref_realm:builtin(<<"evalScript">>, fun(_This, Args) -> buoy_ref_eval:script(arg(1, Args)) end).

define_hidden(G, Name, Value) ->
    _ = buoy_heap:define(G, Name, #{value => Value, writable => true, enumerable => false, configurable => true}),
    ok.

%%% $262.agent (test262 INTERPRETING.md): an agent is a realm process of its own, linked
%%% to the realm of its test, that runs its script as global code through eval. The test
%%% shares a SharedArrayBuffer with broadcast, whose structured clone keeps the atomics
%%% array of its memory, and reads what the agents report through a queue process: the
%%% realm loop takes every message of the realm's own mailbox.

%% The global $262 with its agent object, with the attributes of a `var` of a script. The
%% HOST prelude of the runner adds the rest.
define_host(Agent) ->
    Host = buoy_heap:object(?OBJECT_PROTO, [{<<"agent">>, Agent}]),
    _ = buoy_heap:define({'$o', 'globalThis'}, <<"$262">>, #{value => Host, writable => true, enumerable => true, configurable => false}),
    ok.

main_agent() ->
    agent_object([{<<"start">>, 1, fun start_agent/1},
                  {<<"broadcast">>, 2, fun broadcast/1},
                  {<<"getReport">>, 0, fun(_) -> take_report() end}]).

%% The agent object of an agent's realm.
agent_agent(Reports) ->
    agent_object([{<<"receiveBroadcast">>, 1, fun(Args) -> erlang:put('$262_receiver', arg(1, Args)), undefined end},
                  {<<"report">>, 1, fun(Args) -> Reports ! {report, buoy_heap:clone_out(buoy_ref:to_string(arg(1, Args)))}, undefined end},
                  {<<"leaving">>, 0, fun(_) -> erlang:put('$262_leaving', true), undefined end}]).

%% Functions of (Args), with sleep and monotonicNow, which both kinds of realm have.
agent_object(Functions) ->
    Common = [{<<"sleep">>, 1, fun(Args) -> sleep(buoy_ref:to_number(arg(1, Args))) end},
              {<<"monotonicNow">>, 0, fun(_) -> erlang:convert_time_unit(erlang:monotonic_time() - erlang:system_info(start_time), native, microsecond) / 1000 end}],
    buoy_heap:object(?OBJECT_PROTO, [{Name, buoy_heap:function(fun(_This, Args) -> F(Args) end, Name, Length, #{})}
                                     || {Name, Length, F} <- Functions ++ Common]).

sleep(Ms) when is_number(Ms), Ms > 0 -> timer:sleep(min(ceil(Ms), 16#7FFFFFFF)), undefined;
sleep(_) -> undefined.

%% $262.agent.start(source): returns once the agent runs.
start_agent(Args) ->
    Source = buoy_heap:clone_out(buoy_ref:to_string(arg(1, Args))),
    Test = self(),
    Reports = reports(),
    Stderr = erlang:get('$buoy_stderr'),
    Agent = spawn_opt(fun() -> agent(Test, Reports, Stderr, Source) end,
                      [link, {max_heap_size, #{size => ?AGENT_HEAP_WORDS, kill => true, error_logger => false, include_shared_binaries => true}}]),
    receive {Agent, running} -> ok end,
    erlang:put('$262_agents', [Agent | agents()]),
    undefined.

agents() ->
    case erlang:get('$262_agents') of
        undefined -> [];
        Agents -> Agents
    end.

%% $262.agent.broadcast(sab, number): returns once every agent has taken the message, or
%% has ended.
broadcast(Args) ->
    Message = {buoy_heap:clone_out(arg(1, Args)), buoy_heap:clone_out(arg(2, Args))},
    Tag = make_ref(),
    Agents = [{Agent, erlang:monitor(process, Agent)} || Agent <- agents()],
    [Agent ! {'$262_broadcast', self(), Tag, Message} || {Agent, _} <- Agents],
    [receive
         {Tag, Agent} -> erlang:demonitor(Monitor, [flush]);
         {'DOWN', Monitor, process, Agent, _} -> ok
     end || {Agent, Monitor} <- Agents],
    undefined.

%% $262.agent.getReport(): the oldest report, or null.
take_report() ->
    Ref = make_ref(),
    reports() ! {take, self(), Ref},
    receive
        {Ref, {ok, Report}} -> buoy_heap:clone_in(Report);
        {Ref, none} -> null
    end.

%% The report queue of the test, started with its first agent.
reports() ->
    case erlang:get('$262_reports') of
        undefined ->
            Reports = spawn_link(fun() -> report_queue(queue:new()) end),
            erlang:put('$262_reports', Reports),
            Reports;
        Reports ->
            Reports
    end.

report_queue(Queue) ->
    receive
        {report, Report} ->
            report_queue(queue:in(Report, Queue));
        {take, From, Ref} ->
            case queue:out(Queue) of
                {{value, Report}, Rest} -> From ! {Ref, {ok, Report}}, report_queue(Rest);
                {empty, _} -> From ! {Ref, none}, report_queue(Queue)
            end
    end.

%% The process of an agent: its realm runs the script, then serves broadcasts, timers, and
%% wake messages until it is leaving and has no work left.
agent(Test, Reports, Stderr, Source) ->
    erlang:put('$buoy_exit', true),
    erlang:put('$buoy_stderr', Stderr),
    erlang:put('$buoy_rejections', ignore),
    buoy_ref:init_realm(),
    define_host(agent_agent(Reports)),
    Test ! {self(), running},
    buoy_jobs:run_job(fun() -> buoy_ref_eval:method(<<"globalThis">>, <<"eval">>, undefined, [buoy_heap:clone_in(Source)]) end),
    agent_loop().

agent_loop() ->
    receive
        {'$262_broadcast', From, Tag, {Buffer, Number}} ->
            From ! {Tag, self()},
            case erlang:get('$262_receiver') of
                undefined -> ok;
                Receiver -> buoy_jobs:run_job(fun() -> buoy_heap:call(Receiver, undefined, [buoy_heap:clone_in(Buffer), buoy_heap:clone_in(Number)]) end)
            end;
        Message ->
            buoy_jobs:event_step(Message)
    end,
    case erlang:get('$262_leaving') of
        true -> buoy_jobs:loop();
        _ -> agent_loop()
    end.

%%% An I/O server that keeps what a realm writes.

capture() -> spawn(fun() -> capture([]) end).

capture(Acc) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Acc1} = request(Request, Acc),
            From ! {io_reply, ReplyAs, Reply},
            capture(Acc1);
        {collect, From} ->
            From ! {captured, self(), lists:reverse(Acc)}
    end.

request({put_chars, Encoding, Chars}, Acc) ->
    case unicode:characters_to_binary(Chars, Encoding, utf8) of
        Text when is_binary(Text) -> {ok, [Text | Acc]};
        _ -> {{error, put_chars}, Acc}
    end;
request({put_chars, Encoding, M, F, A}, Acc) ->
    request({put_chars, Encoding, apply(M, F, A)}, Acc);
request({requests, Requests}, Acc) ->
    lists:foldl(fun(R, {_, A}) -> request(R, A) end, {ok, Acc}, Requests);
request(getopts, Acc) ->
    {[{encoding, unicode}], Acc};
request({setopts, _}, Acc) ->
    {ok, Acc};
request(_, Acc) ->
    {{error, enotsup}, Acc}.

collect(Capture) ->
    Capture ! {collect, self()},
    receive
        {captured, Capture, Output} -> Output
    after 5000 -> <<>>
    end.
