-module(buoy_test_runtime).

%% Starts the runtime for a test fixture, names the fixture classes, and reads
%% the JavaScript errors that runtime calls throw.

-export([start/0, stop/1]).
-export([counter/0, slow/0, relay/0, broken/0, moody/0, quitter/0]).
-export([thrown/1, tag/1, entry/1, pid/1, await/1, capture_stderr/1, capture_logs/1]).
-export([log/2]).

-spec start() -> ok.
start() ->
    {ok, _Started} = application:ensure_all_started(buoy),
    ok.

-spec stop(term()) -> ok.
stop(_) ->
    ok = application:stop(buoy).

-spec counter() -> {'$class', module(), binary()}.
counter() -> {'$class', buoy_fixture_counter, <<"Counter">>}.

-spec slow() -> {'$class', module(), binary()}.
slow() -> {'$class', buoy_fixture_slow, <<"Slow">>}.

-spec relay() -> {'$class', module(), binary()}.
relay() -> {'$class', buoy_fixture_relay, <<"Relay">>}.

-spec broken() -> {'$class', module(), binary()}.
broken() -> {'$class', buoy_fixture_lifecycle, <<"Broken">>}.

-spec moody() -> {'$class', module(), binary()}.
moody() -> {'$class', buoy_fixture_lifecycle, <<"Moody">>}.

-spec quitter() -> {'$class', module(), binary()}.
quitter() -> {'$class', buoy_fixture_lifecycle, <<"Quitter">>}.

%% The JavaScript value that Fun throws.
-spec thrown(fun(() -> term())) -> term().
thrown(Fun) ->
    try Fun() of
        Value -> erlang:error({expected_a_throw, Value})
    catch
        error:{'$throw', Thrown} -> Thrown
    end.

-spec tag(fun(() -> term())) -> binary().
tag(Fun) ->
    maps:get(<<"_tag">>, thrown(Fun)).

%% The inspect() entry of Ref.
-spec entry({'$ref', pos_integer()}) -> map().
entry({'$ref', Id}) ->
    [Entry] = [Entry || #{<<"id">> := EntryId} = Entry <- buoy:inspect([]), EntryId =:= Id],
    Entry.

%% The current process of Ref.
-spec pid({'$ref', pos_integer()}) -> pid() | undefined.
pid({'$ref', Id}) ->
    {ok, #{pid := Pid}} = buoy_registry:find(Id),
    Pid.

%% Waits until Predicate holds, for at most 10 seconds.
-spec await(fun(() -> boolean())) -> ok.
await(Predicate) ->
    await(Predicate, 1000).

await(_Predicate, 0) ->
    erlang:error(await_timed_out);
await(Predicate, Tries) ->
    case Predicate() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            await(Predicate, Tries - 1)
    end.

%% Runs Fun while a stand-in for the standard_error device records the text
%% that it prints. Returns the result of Fun and the text.
-spec capture_stderr(fun(() -> term())) -> {term(), binary()}.
capture_stderr(Fun) ->
    Device = whereis(standard_error),
    Recorder = spawn(fun() -> record([]) end),
    true = unregister(standard_error),
    true = register(standard_error, Recorder),
    Result =
        try
            Fun()
        after
            true = unregister(standard_error),
            true = register(standard_error, Device)
        end,
    Recorder ! {dump, self()},
    receive
        {recorded, Text} -> {Result, Text}
    end.

record(Chunks) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, ok},
            record([chars(Request) | Chunks]);
        {dump, Pid} ->
            Pid ! {recorded, unicode:characters_to_binary(lists:reverse(Chunks))}
    end.

chars({put_chars, _Encoding, Chars}) -> Chars;
chars({put_chars, _Encoding, Module, Function, Args}) -> apply(Module, Function, Args);
chars(_Request) -> [].

%% Runs Fun while a logger handler sends every event that passes the primary
%% filters to the calling process. Returns the result of Fun and the events
%% that arrived within 200 ms after Fun returned.
-spec capture_logs(fun(() -> term())) -> {term(), [logger:log_event()]}.
capture_logs(Fun) ->
    ok = logger:add_handler(buoy_test_capture, ?MODULE, #{config => #{pid => self()}}),
    Result =
        try
            Fun()
        after
            timer:sleep(200),
            ok = logger:remove_handler(buoy_test_capture)
        end,
    {Result, logged()}.

logged() ->
    receive
        {logged, Event} -> [Event | logged()]
    after 0 -> []
    end.

%% The logger handler callback of capture_logs/1.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Event},
    ok.
