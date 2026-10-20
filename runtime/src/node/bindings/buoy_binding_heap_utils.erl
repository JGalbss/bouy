%% internalBinding('heap_utils') (src/heap_utils.cc): heap snapshots of the
%% realm in V8's .heapsnapshot format. The JavaScript heap of a realm is the
%% records of buoy_heap in its process dictionary: each object, function, and
%% cell record is a node, each property, element, and prototype is an edge,
%% and the records under keys that are no integer, which the collector marks
%% from, hang off the synthetic root.
-module(buoy_binding_heap_utils).

-export([binding/0]).

-include("buoy_ref.hrl").

-define(PROTO, {?MODULE, stream_proto}).
-define(SEQUENCE, {?MODULE, sequence}).
-define(ROOT(Handle), {?MODULE, root, Handle}).
-define(CHUNK, 65536).
-define(NODE_FIELDS, 6).

%% The node and edge types of V8 13, in the order of HeapGraphNode::Type and
%% HeapGraphEdge::Type.
-define(NODE_TYPES, [<<"hidden">>, <<"array">>, <<"string">>, <<"object">>, <<"code">>, <<"closure">>,
                     <<"regexp">>, <<"number">>, <<"native">>, <<"synthetic">>, <<"concatenated string">>,
                     <<"sliced string">>, <<"symbol">>, <<"bigint">>, <<"object shape">>]).
-define(EDGE_TYPES, [<<"context">>, <<"element">>, <<"property">>, <<"internal">>, <<"hidden">>,
                     <<"shortcut">>, <<"weak">>]).
-define(OBJECT, 3).
-define(CLOSURE, 5).
-define(SYNTHETIC, 9).
-define(ELEMENT, 1).
-define(PROPERTY, 2).
-define(INTERNAL, 3).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    buoy_node:object(
        [{<<"createHeapSnapshotStream">>, F(<<"createHeapSnapshotStream">>, 1, fun(_, _) -> snapshot_stream() end)},
         {<<"triggerHeapSnapshot">>, F(<<"triggerHeapSnapshot">>, 2, fun(_, Args) -> write_snapshot(A(1, Args)) end)}]
        ++ buoy_node:stubs(<<"heap_utils">>, [<<"buildEmbedderGraph">>])).

%% A stream handle that reads the snapshot, as HeapSnapshotStream of
%% heap_utils.cc. Its channel is a process that has exited, since no process
%% writes to it: the snapshot is queued for readStart at once. The handle
%% stays a root of the heap until readStart has delivered the queue, since
%% only the queued callbacks may name it by then.
snapshot_stream() ->
    Handle = buoy_heap:new_object(stream_proto()),
    ok = buoy_node_stream:attach(Handle, spawn(fun() -> ok end)),
    erlang:put(?ROOT(Handle), Handle),
    Bytes = snapshot(),
    [buoy_node_stream:deliver(Handle, Chunk) || Chunk <- chunks(Bytes)],
    buoy_node_stream:deliver(Handle, eof),
    Handle.

stream_proto() ->
    case erlang:get(?PROTO) of
        undefined ->
            Proto = buoy_node:object([]),
            ok = buoy_node_stream:methods(Proto),
            ReadStart = buoy_heap:get(Proto, <<"readStart">>),
            buoy_heap:set(Proto, <<"readStart">>, buoy_node:fn(<<"readStart">>, 0, fun(This, Args) ->
                Result = buoy_heap:call(ReadStart, This, Args),
                buoy_node_stream:call(self(), fun() -> erlang:erase(?ROOT(This)) end),
                Result
            end)),
            erlang:put(?PROTO, Proto),
            Proto;
        Proto ->
            Proto
    end.

chunks(<<Chunk:?CHUNK/binary, Rest/binary>>) when Rest =/= <<>> -> [Chunk | chunks(Rest)];
chunks(Bytes) -> [Bytes].

%% triggerHeapSnapshot(filename, options): writes the snapshot to filename,
%% or to Heap.<date>.<time>.<pid>.<thread>.<seq>.heapsnapshot in
%% --diagnostic-dir or the working directory, and returns the name.
write_snapshot(Filename) ->
    Name = case Filename of
        undefined -> default_filename();
        _ -> buoy_binding_fs:path(Filename)
    end,
    case file:write_file(Name, snapshot()) of
        ok -> buoy_node:string(Name);
        {error, Reason} -> buoy_binding_fs:uv_error(Reason, <<"open">>, Name)
    end.

%% DiagnosticFilename::MakeFilename of Node.
default_filename() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
    Sequence = case erlang:get(?SEQUENCE) of undefined -> 1; N -> N end,
    erlang:put(?SEQUENCE, Sequence + 1),
    Name = io_lib:format("Heap.~4..0B~2..0B~2..0B.~2..0B~2..0B~2..0B.~s.0.~3..0B.heapsnapshot",
                         [Y, Mo, D, H, Mi, S, os:getpid(), Sequence]),
    case buoy_binding_options:value(<<"--diagnostic-dir">>) of
        <<>> -> iolist_to_binary(Name);
        Directory -> iolist_to_binary([Directory, $/, Name])
    end.

%%% The snapshot

%% The JSON text of the snapshot of this realm's heap.
snapshot() ->
    Records = [{Key, Record} || {Key, Record} <- erlang:get(), is_record_key(Key), is_heap_record(Record)],
    Index = maps:from_list(lists:zip([Key || {Key, _} <- Records], lists:seq(1, length(Records)))),
    Roots = [I || {Key, _} <- Records, not is_integer(Key), I <- [maps:get(Key, Index)]],
    {Nodes, Edges, Strings} = graph(Records, Index, Roots),
    StringList = [S || {S, _} <- lists:keysort(2, maps:to_list(Strings))],
    iolist_to_binary(
      [<<"{\"snapshot\":{\"meta\":{\"node_fields\":[\"type\",\"name\",\"id\",\"self_size\",\"edge_count\",\"detachedness\"],">>,
       <<"\"node_types\":[">>, json:encode(?NODE_TYPES), <<",\"string\",\"number\",\"number\",\"number\",\"number\"],">>,
       <<"\"edge_fields\":[\"type\",\"name_or_index\",\"to_node\"],">>,
       <<"\"edge_types\":[">>, json:encode(?EDGE_TYPES), <<",\"string_or_number\",\"node\"],">>,
       <<"\"trace_function_info_fields\":[\"function_id\",\"name\",\"script_name\",\"script_id\",\"line\",\"column\"],">>,
       <<"\"trace_node_fields\":[\"id\",\"function_info_index\",\"count\",\"size\",\"children\"],">>,
       <<"\"sample_fields\":[\"timestamp_us\",\"last_assigned_id\"],">>,
       <<"\"location_fields\":[\"object_index\",\"script_id\",\"line\",\"column\"]},">>,
       <<"\"node_count\":">>, integer_to_binary(length(Records) + 1),
       <<",\"edge_count\":">>, integer_to_binary(length(Edges) div 3),
       <<",\"extra_native_bytes\":0,\"trace_function_count\":0},">>,
       <<"\"nodes\":">>, numbers(Nodes), <<",\"edges\":">>, numbers(Edges),
       <<",\"trace_function_infos\":[],\"trace_tree\":[],\"samples\":[],\"locations\":[],\"strings\":">>,
       json:encode(StringList), <<"}">>]).

numbers(List) -> [$[, lists:join($,, [integer_to_binary(N) || N <- List]), $]].

%% An object record lives under an integer id, an intrinsic atom, or {N, Atom}
%% for the intrinsic of the realm N.
is_record_key(Key) when is_integer(Key); is_atom(Key) -> true;
is_record_key({N, Atom}) when is_integer(N), is_atom(Atom) -> true;
is_record_key(_) -> false.

is_heap_record({Class, _, Props, Keys, Attrs, _}) when is_atom(Class), is_map(Props), is_list(Keys), is_map(Attrs) -> true;
is_heap_record(_) -> false.

%% The flat node and edge arrays, the root first, and the string table.
graph(Records, Index, Roots) ->
    Strings0 = #{<<"">> => 0},
    RootEdges = lists:append([[?ELEMENT, N, I * ?NODE_FIELDS] || {N, I} <- lists:enumerate(1, Roots)]),
    {RootName, Strings1} = string(<<"(GC roots)">>, Strings0),
    Root = [?SYNTHETIC, RootName, 1, 0, length(Roots), 0],
    {Nodes, Edges, Strings} = lists:foldl(
        fun({{_Key, Record}, Position}, {NodeAcc, EdgeAcc, S0}) ->
                {Type, Name} = describe(Record),
                {NameIndex, S1} = string(Name, S0),
                {Out, S2} = edges(Record, Index, S1),
                Node = [Type, NameIndex, Position * 2 + 1, self_size(Record), length(Out) div 3, 0],
                {[Node | NodeAcc], [Out | EdgeAcc], S2}
        end,
        {[], [], Strings1}, lists:zip(Records, lists:seq(1, length(Records)))),
    {Root ++ lists:append(lists:reverse(Nodes)), RootEdges ++ lists:append(lists:reverse(Edges)), Strings}.

string(Text, Strings) ->
    case Strings of
        #{Text := I} -> {I, Strings};
        _ -> I = map_size(Strings), {I, Strings#{Text => I}}
    end.

%% The node type and the name that V8 gives: a function is a closure named
%% for its name, and an object is named for its class.
describe({function, _, Props, _, _, _}) ->
    case maps:get(<<"name">>, Props, undefined) of
        Name when ?IS_STRING(Name) -> {?CLOSURE, buoy_ref_string:to_utf8(Name)};
        _ -> {?CLOSURE, <<"">>}
    end;
describe({Class, _, _, _, _, _}) ->
    {?OBJECT, class_name(Class)}.

class_name(Class) ->
    case atom_to_binary(Class) of
        <<C, Rest/binary>> when C >= $a, C =< $z -> <<(C - 32), Rest/binary>>;
        Name -> Name
    end.

self_size(Record) -> erts_debug:flat_size(Record) * erlang:system_info(wordsize).

%% The edges of a record: the prototype, each property by its key, and each
%% value that its internal slots hold.
edges({_, Proto, Props, _, _, Slots}, Index, Strings) ->
    Named = [{<<"__proto__">>, Proto} | maps:to_list(Props)],
    {Edges, Strings1} = lists:foldl(
        fun({Key, Value}, {Acc, S}) ->
                case targets(Value, Index) of
                    [] -> {Acc, S};
                    Targets ->
                        {Type, Name, S1} = edge_name(Key, S),
                        {[[[Type, Name, T * ?NODE_FIELDS] || T <- Targets] | Acc], S1}
                end
        end, {[], Strings}, Named),
    Internal = [[?INTERNAL, 0, T * ?NODE_FIELDS] || T <- targets(Slots, Index)],
    {lists:append(lists:append(lists:reverse(Edges))) ++ lists:append(Internal), Strings1}.

edge_name(Key, Strings) when is_integer(Key) -> {?ELEMENT, Key, Strings};
edge_name(Key, Strings) when is_binary(Key) ->
    {I, S} = string(buoy_ref_string:to_utf8(Key), Strings),
    {?PROPERTY, I, S};
edge_name(_, Strings) ->
    {I, S} = string(<<"<symbol>">>, Strings),
    {?INTERNAL, I, S}.

%% The nodes that a term refers to: the records of the objects and functions
%% in it.
targets(Term, Index) -> lists:usort(targets(Term, Index, [])).

targets({'$o', Key}, Index, Acc) -> target(Key, Index, Acc);
targets({'$f', Key, _}, Index, Acc) -> target(Key, Index, Acc);
targets(Tuple, Index, Acc) when is_tuple(Tuple) -> targets(tuple_to_list(Tuple), Index, Acc);
targets([H | T], Index, Acc) -> targets(T, Index, targets(H, Index, Acc));
targets(Map, Index, Acc) when is_map(Map) -> targets(maps:values(Map), Index, Acc);
targets(_, _, Acc) -> Acc.

target(Key, Index, Acc) ->
    case Index of
        #{Key := I} -> [I | Acc];
        _ -> Acc
    end.
