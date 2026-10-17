%% The VM half of the test262 development runner (crates/bouy-cli/src/bin/test262-dev.rs):
%% one VM runs many compiled tests, each in a realm process of its own, so a test does
%% not pay for the start of a VM.
%%
%%   erl ... -pa <runtime ebin> -pa <dir of this module> -eval 'bouy_test262:main()'
%%       -extra <manifest> <jobs> <output dir>
%%
%% Each line of the manifest is "<index>\t<erl file>,...\t<timeout ms>": the entry module
%% of the test, then the modules it imports. For each test, the runner prints
%% "START <index>", loads the imported modules once per VM (tests share fixtures), compiles
%% and loads the entry module, runs it with stdout and stderr captured into
%% <output dir>/<index>.out and .err, and prints "DONE <index> <status>": the exit status,
%% timeout, memory, or compile.
-module(bouy_test262).

-export([main/0]).

%% A realm that grows past this many words (256 MB), counting the large binaries it
%% holds, ends with the outcome `memory`. bouy_guard caps the whole VM.
-define(MAX_HEAP_WORDS, 32 * 1024 * 1024).

-spec main() -> no_return().
main() ->
    ok = bouy_guard:start(),
    [Manifest, Jobs, Out] = init:get_plain_arguments(),
    {ok, Text} = file:read_file(Manifest),
    Tests = list_to_tuple([parse(Line) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])]),
    {ok, Runtime} = bouy_app:start(normal, []),
    true = unlink(Runtime),
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

%% Loads each imported module once: tests that run at once share fixtures, and a
%% second load of a module in use would purge the code that a realm runs.
loader(Loaded) ->
    receive
        {load, File, From} ->
            Result = case Loaded of
                #{File := Known} -> Known;
                _ -> load(File)
            end,
            From ! {loaded, File, Result},
            loader(Loaded#{File => Result})
    end.

load(File) ->
    case compile:file(File, [binary, return_errors, nowarn_unused_vars]) of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, File, Binary),
            ok;
        Failed ->
            {error, Failed}
    end.

load_imports(Imports, Loader) ->
    lists:foldl(fun(File, ok) ->
                        Loader ! {load, File, self()},
                        receive {loaded, File, Result} -> Result end;
                   (_, Failed) ->
                        Failed
                end, ok, Imports).

run({Index, File, Imports, Timeout}, Out, Loader) ->
    io:format("START ~ts~n", [Index]),
    Base = filename:join(Out, binary_to_list(Index)),
    Compiled = case load_imports(Imports, Loader) of
        ok -> compile:file(File, [binary, return_errors, nowarn_unused_vars]);
        ImportFailed -> ImportFailed
    end,
    Status = case Compiled of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, File, Binary),
            Result = execute(Module, Timeout, Base),
            _ = code:purge(Module),
            _ = code:delete(Module),
            _ = code:purge(Module),
            Result;
        {error, Rejected} ->
            ok = file:write_file(Base ++ ".err", io_lib:format("the Erlang compiler rejected an imported module: ~0tP~n", [Rejected, 12])),
            ok = file:write_file(Base ++ ".out", <<>>),
            "compile";
        Failed ->
            ok = file:write_file(Base ++ ".err", io_lib:format("the Erlang compiler rejected the module: ~0tP~n", [Failed, 12])),
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
        {'DOWN', Ref, process, Pid, {'$bouy_exit', Code}} -> integer_to_list(Code);
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
    erlang:put('$bouy_exit', true),
    erlang:put('$bouy_stderr', Stderr),
    try Module:'__init__'() of
        _ -> exit({'$bouy_exit', 0})
    catch
        exit:{'$bouy_exit', _} = Exit ->
            exit(Exit);
        Class:Reason:Stack ->
            io:put_chars(Stderr, io_lib:format("Uncaught ~p: ~0tP ~0tP~n", [Class, Reason, 12, Stack, 12])),
            exit({'$bouy_exit', 1})
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
