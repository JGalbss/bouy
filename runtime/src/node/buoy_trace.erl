%% The trace agent of Node (src/tracing/agent.cc and node_trace_writer.cc)
%% for the whole VM. The command line and each enabled CategorySet add their
%% categories to one multiset, and one writer process streams the events of
%% every realm to node_trace.${rotation}.log in the JSON format of V8's
%% JSONTraceWriter. A category group such as "node,node.fs,node.fs.sync" is
%% enabled when one of its categories is, as V8's TraceConfig decides.
-module(buoy_trace).

-export([start_cli/0, start/0, add/1, remove/1, categories/0, enabled/1]).
-export([event/5, complete/3, scope/3, open_scope/3, close_scope/2, instant/3, metadata/2, stop/0]).
-export([pool_work/2]).

%% The enabled categories, each with its count: #{Category => Count}.
-define(CATEGORIES, {?MODULE, categories}).
%% The file pattern of --trace-event-file-pattern, once tracing started.
-define(PATTERN, {?MODULE, pattern}).
-define(WRITER, ?MODULE).
%% kTracesPerFile of NodeTraceWriter: a file ends after this many events.
-define(TRACES_PER_FILE, 1 bsl 19).
%% The events that the writer keeps before it writes them.
-define(BATCH, 512).

%% StartTracingAgent of node.cc for --trace-event-categories: a value that is
%% not empty starts the writer, and its comma-separated categories turn on.
-spec start_cli() -> ok.
start_cli() ->
    case lists:any(fun is_trace_option/1, buoy_node_process:exec_argv()) of
        false ->
            ok;
        true ->
            case buoy_binding_options:value(<<"--trace-event-categories">>) of
                <<>> -> ok;
                Categories -> start(), add(split(Categories))
            end
    end.

is_trace_option(<<"--trace-event", _/binary>>) -> true;
is_trace_option(<<"--trace_event", _/binary>>) -> true;
is_trace_option(_) -> false.

split(Categories) -> [C || C <- binary:split(Categories, <<",">>, [global]), C =/= <<>>].

%% Starts the writer once, with the file pattern of the command line, and
%% records the metadata of the process, as node.cc does at startup.
-spec start() -> ok.
start() ->
    case whereis(?WRITER) of
        undefined ->
            Pattern = buoy_binding_options:value(<<"--trace-event-file-pattern">>),
            Pid = spawn(fun() -> writer(#{pattern => Pattern, rotation => 0, fd => none, count => 0, pending => [], size => 0}) end),
            try register(?WRITER, Pid) of
                true -> process_metadata(Pid)
            catch
                error:badarg -> exit(Pid, kill)
            end,
            ok;
        _ ->
            ok
    end.

process_metadata(Writer) ->
    Versions = buoy_node_process:version_pairs(),
    {_, NodeVersion} = lists:keyfind(<<"node">>, 1, Versions),
    metadata(<<"thread_name">>, [{<<"name">>, <<"JavaScriptMainThread">>}]),
    %% The writer is the thread of the platform that writes the file.
    Writer ! {event, encode(Writer, timestamp(), <<"M">>, <<"__metadata">>, <<"thread_name">>, 0, none,
                            [{<<"name">>, <<"PlatformWorkerThread">>}])},
    metadata(<<"version">>, [{<<"node">>, NodeVersion}]),
    metadata(<<"node">>, [{<<"process">>, #{
        <<"versions">> => maps:from_list(Versions),
        <<"arch">> => buoy_node_process:arch(),
        <<"platform">> => buoy_node_process:platform(),
        <<"release">> => #{<<"name">> => <<"node">>}}}]),
    metadata(<<"process_name">>, [{<<"name">>, buoy_node_process:initial_title()}]).

%% Agent::Enable and the client of the command line: each category counts once more.
-spec add([binary()]) -> ok.
add(Categories) ->
    update(fun(Map) -> lists:foldl(fun(C, M) -> maps:update_with(C, fun(N) -> N + 1 end, 1, M) end, Map, Categories) end).

%% Agent::Disable: each category counts once less.
-spec remove([binary()]) -> ok.
remove(Categories) ->
    update(fun(Map) ->
        lists:foldl(fun(C, M) ->
            case M of
                #{C := 1} -> maps:remove(C, M);
                #{C := N} -> M#{C := N - 1};
                _ -> M
            end
        end, Map, Categories)
    end).

update(Fun) ->
    Old = persistent_term:get(?CATEGORIES, #{}),
    case Fun(Old) of
        Old -> ok;
        New -> persistent_term:put(?CATEGORIES, New)
    end.

%% The enabled categories, sorted, as Agent::GetEnabledCategories flattens them.
-spec categories() -> [binary()].
categories() -> lists:sort(maps:keys(persistent_term:get(?CATEGORIES, #{}))).

-spec enabled(binary()) -> boolean().
enabled(Group) ->
    case persistent_term:get(?CATEGORIES, #{}) of
        Map when map_size(Map) =:= 0 -> false;
        Map -> lists:any(fun(C) -> is_map_key(C, Map) end, binary:split(Group, <<",">>, [global]))
    end.

%% An event of Phase, such as $b, in the category group Group, with an
%% optional id and the arguments Args: each a name and a term for
%% json:encode, or {json, Text} for a value that is JSON already.
-spec event(char(), binary(), binary(), none | integer(), [{binary(), term()}]) -> ok.
event(Phase, Group, Name, Id, Args) ->
    case enabled(Group) of
        true -> send(<<Phase/utf8>>, Group, Name, 0, Id, Args);
        false -> ok
    end.

%% TRACE_EVENT0: Fun runs inside a complete event of Name.
-spec complete(binary(), binary(), fun(() -> T)) -> T.
complete(Group, Name, Fun) ->
    case enabled(Group) of
        false ->
            Fun();
        true ->
            Start = timestamp(),
            try Fun()
            after
                send(<<"X">>, Group, Name, timestamp() - Start, none, [], Start)
            end
    end.

%% TraceEventScope of env.h: Fun runs between a nestable async begin and
%% end of Name, whose id is the realm's.
-spec scope(binary(), binary(), fun(() -> T)) -> T.
scope(Group, Name, Fun) ->
    case enabled(Group) of
        false ->
            Fun();
        true ->
            open_scope(Group, Name, []),
            try Fun()
            after
                close_scope(Group, Name)
            end
    end.

%% The begin and the end of a scope that spans more than one call.
-spec open_scope(binary(), binary(), [{binary(), term()}]) -> ok.
open_scope(Group, Name, Args) -> event($b, Group, Name, tid(self()), Args).

-spec close_scope(binary(), binary()) -> ok.
close_scope(Group, Name) -> event($e, Group, Name, tid(self()), []).

%% ThreadPoolWork of threadpoolwork-inl.h, such as a crypto job or a zlib
%% write of Type: a nestable async begin when the realm queues the work, a
%% begin and an end around Work in the process that runs it, and the async
%% end when the result is back. Returns a fun for the worker that runs Work
%% and gives its result, and a fun for the realm that ends the async event.
-spec pool_work(binary(), fun(() -> T)) -> {fun(() -> T), fun(() -> ok)}.
pool_work(Type, Work) ->
    Async = <<"node,node.threadpoolwork,node.threadpoolwork.async">>,
    Sync = <<"node,node.threadpoolwork,node.threadpoolwork.sync">>,
    Id = erlang:unique_integer([positive]),
    event($b, Async, Type, Id, []),
    {fun() ->
         event($B, Sync, Type, none, []),
         try Work()
         after
             event($E, Sync, Type, none, [])
         end
     end,
     fun() -> event($e, Async, Type, Id, [{<<"result">>, 0}]) end}.

%% TRACE_EVENT_INSTANT_WITH_TIMESTAMP0, with a time in microseconds since
%% the VM started.
-spec instant(binary(), binary(), integer()) -> ok.
instant(Group, Name, Time) ->
    case enabled(Group) of
        true -> send(<<"I">>, Group, Name, 0, none, [], Time);
        false -> ok
    end.

%% TRACE_EVENT_METADATA1: always recorded while the writer runs.
-spec metadata(binary(), [{binary(), term()}]) -> ok.
metadata(Name, Args) ->
    case whereis(?WRITER) of
        undefined -> ok;
        Writer -> Writer ! {event, encode(self(), timestamp(), <<"M">>, <<"__metadata">>, Name, 0, none, Args)}, ok
    end.

send(Phase, Group, Name, Duration, Id, Args) ->
    send(Phase, Group, Name, Duration, Id, Args, timestamp()).

send(Phase, Group, Name, Duration, Id, Args, Time) ->
    case whereis(?WRITER) of
        undefined -> ok;
        Writer -> Writer ! {event, encode(self(), Time, Phase, Group, Name, Duration, Id, Args)}, ok
    end.

%% The clock of the events, as uv_hrtime() / 1000 is Node's: microseconds
%% since the VM started, the origin of process.hrtime.
timestamp() ->
    erlang:monotonic_time(microsecond) - erlang:convert_time_unit(erlang:system_info(start_time), native, microsecond).

%% JSONTraceWriter::AppendTraceEvent. Buoy measures no thread time, so tts
%% and tdur are 0.
encode(Pid, Time, Phase, Group, Name, Duration, Id, Args) ->
    IdField = case Id of
        none -> [];
        _ -> [<<",\"id\":\"0x">>, string:lowercase(integer_to_binary(Id band 16#FFFFFFFFFFFFFFFF, 16)), <<"\"">>]
    end,
    iolist_to_binary([
        <<"{\"pid\":">>, os:getpid(), <<",\"tid\":">>, integer_to_binary(tid(Pid)),
        <<",\"ts\":">>, integer_to_binary(Time), <<",\"tts\":0,\"ph\":">>, json:encode(Phase),
        <<",\"cat\":">>, json:encode(Group), <<",\"name\":">>, json:encode(Name),
        <<",\"dur\":">>, integer_to_binary(Duration), <<",\"tdur\":0">>, IdField,
        <<",\"args\":{">>, lists:join(<<",">>, [[json:encode(K), <<":">>, json_value(V)] || {K, V} <- Args]), <<"}}">>]).

json_value({json, Text}) -> Text;
json_value(Value) -> json:encode(Value).

%% A realm is a thread of Node: the number of its process.
tid(Pid) ->
    [_, N, _] = string:lexemes(erlang:pid_to_list(Pid), "<.>"),
    list_to_integer(N).

%% Ends tracing before the VM halts: the writer writes what it holds and ends
%% the file, as the destructor of NodeTraceWriter does.
-spec stop() -> ok.
stop() ->
    case whereis(?WRITER) of
        undefined ->
            ok;
        Writer ->
            Ref = monitor(process, Writer),
            Writer ! {stop, self(), Ref},
            receive
                {Ref, done} -> demonitor(Ref, [flush]), ok;
                {'DOWN', Ref, _, _, _} -> ok
            after 10000 -> ok
            end
    end.

%%% The writer

writer(State) ->
    receive
        {event, Json} ->
            writer(append(Json, State));
        {stop, From, Ref} ->
            _ = close(flush(State)),
            From ! {Ref, done}
    end.

%% The first event of a file opens it and starts the JSON object; the event
%% after kTracesPerFile of them ends the file.
append(Json, #{count := 0} = State) ->
    append_to(Json, open(State));
append(Json, State) ->
    append_to([<<",">>, Json], State).

append_to(Json, #{count := Count, pending := Pending, size := Size} = State) ->
    Next = State#{count := Count + 1, pending := [Json | Pending], size := Size + 1},
    case Count + 1 >= ?TRACES_PER_FILE of
        true -> (close(flush(Next)))#{count := 0};
        false when Size + 1 >= ?BATCH -> flush(Next);
        false -> Next
    end.

%% OpenNewFileForStreaming: the next rotation of the pattern, truncated.
open(#{pattern := Pattern, rotation := Rotation, pending := Pending} = State) ->
    Next = Rotation + 1,
    Path = lists:foldl(fun({Key, Value}, P) -> binary:replace(P, Key, Value, [global]) end, Pattern,
                       [{<<"${pid}">>, list_to_binary(os:getpid())}, {<<"${rotation}">>, integer_to_binary(Next)}]),
    Fd = case file:open(Path, [write, raw, binary]) of
        {ok, F} ->
            F;
        {error, Reason} ->
            io:format(standard_error, "Could not open trace file ~ts: ~ts~n", [Path, file:format_error(Reason)]),
            none
    end,
    State#{rotation := Next, fd := Fd, pending := [<<"{\"traceEvents\":[">> | Pending]}.

flush(#{pending := []} = State) ->
    State;
flush(#{fd := Fd, pending := Pending} = State) ->
    _ = Fd =/= none andalso file:write(Fd, lists:reverse(Pending)),
    State#{pending := [], size := 0}.

close(#{fd := none} = State) ->
    State;
close(#{fd := Fd, count := Count} = State) when Count > 0 ->
    _ = file:write(Fd, <<"]}">>),
    _ = file:close(Fd),
    State#{fd := none};
close(State) ->
    State.
