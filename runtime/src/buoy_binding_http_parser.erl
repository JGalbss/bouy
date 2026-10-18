%% internalBinding('http_parser') (src/node_http_parser.cc): HTTPParser over
%% buoy_llhttp, and ConnectionsList, which the server's timeouts read.
%%
%% Bun ports this file over its vendored llhttp (src/jsc/bindings/node/http/
%% NodeHTTPParser.cpp), and like Bun, consume() leaves the socket in
%% JavaScript: the bytes reach execute() through the socket's 'data' events,
%% so kOnExecute never runs.
%%
%% The state of a parser lives in its private slot. A callback can call back
%% into the parser (remove, pause, or initialize a reused parser), so each
%% JavaScript callback saves the state first and reads it again after.
-module(buoy_binding_http_parser).

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"parser">>}).
-define(LIST, {'#', ?MODULE, <<"connections">>}).
-define(MAX_HEADER_SIZE, {?MODULE, max_http_header_size}).

-define(K_ON_MESSAGE_BEGIN, 0).
-define(K_ON_HEADERS, 1).
-define(K_ON_HEADERS_COMPLETE, 2).
-define(K_ON_BODY, 3).
-define(K_ON_MESSAGE_COMPLETE, 4).
-define(K_ON_EXECUTE, 5).
-define(K_ON_TIMEOUT, 6).
-define(MAX_HEADER_FIELDS, 32).
-define(MAX_CHUNK_EXTENSIONS_SIZE, 16384).
-define(REQUEST, 1).
-define(RESPONSE, 2).

-spec binding() -> term().
binding() ->
    buoy_node:object([{<<"HTTPParser">>, parser_class()},
                      {<<"ConnectionsList">>, connections_class()},
                      {<<"methods">>, buoy_heap:new_array(buoy_llhttp:methods())},
                      {<<"allMethods">>, buoy_heap:new_array(buoy_llhttp:all_methods())}]).

parser_class() ->
    Class = buoy_node:constructor(<<"HTTPParser">>, 0, fun(This, _) -> new(This) end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    buoy_heap:set_prototype_of(Proto, async_wrap_prototype()),
    Constants = [{<<"REQUEST">>, ?REQUEST}, {<<"RESPONSE">>, ?RESPONSE},
                 {<<"kOnMessageBegin">>, ?K_ON_MESSAGE_BEGIN}, {<<"kOnHeaders">>, ?K_ON_HEADERS},
                 {<<"kOnHeadersComplete">>, ?K_ON_HEADERS_COMPLETE}, {<<"kOnBody">>, ?K_ON_BODY},
                 {<<"kOnMessageComplete">>, ?K_ON_MESSAGE_COMPLETE}, {<<"kOnExecute">>, ?K_ON_EXECUTE},
                 {<<"kOnTimeout">>, ?K_ON_TIMEOUT},
                 {<<"kLenientNone">>, 0}, {<<"kLenientHeaders">>, 1}, {<<"kLenientChunkedLength">>, 2},
                 {<<"kLenientKeepAlive">>, 4}, {<<"kLenientTransferEncoding">>, 8}, {<<"kLenientVersion">>, 16},
                 {<<"kLenientDataAfterClose">>, 32}, {<<"kLenientOptionalLFAfterCR">>, 64},
                 {<<"kLenientOptionalCRLFAfterChunk">>, 128}, {<<"kLenientOptionalCRBeforeLF">>, 256},
                 {<<"kLenientSpacesAfterChunkSize">>, 512}, {<<"kLenientAll">>, 1023}],
    [buoy_heap:define(Class, K, #{value => V, writable => true, enumerable => true, configurable => true})
     || {K, V} <- Constants],
    A = fun buoy_node:arg/2,
    methods(Proto, ?STATE, [{<<"close">>, fun(This, _) -> close(This) end},
                    {<<"free">>, fun(_, _) -> undefined end},
                    {<<"remove">>, fun(This, _) -> remove(This) end},
                    {<<"execute">>, fun(This, Args) -> execute(This, A(1, Args)) end},
                    {<<"finish">>, fun(This, _) -> finish(This) end},
                    {<<"initialize">>, fun(This, Args) -> initialize(This, Args) end},
                    {<<"pause">>, fun(This, _) -> with_parser(This, fun buoy_llhttp:pause/1) end},
                    {<<"resume">>, fun(This, _) -> with_parser(This, fun buoy_llhttp:resume/1) end},
                    {<<"consume">>, fun(_, _) -> undefined end},
                    {<<"unconsume">>, fun(_, _) -> undefined end},
                    {<<"getCurrentBuffer">>, fun(This, _) -> current_buffer(This) end}]),
    Class.

%% The methods that HTTPParser inherits from AsyncWrap.
async_wrap_prototype() ->
    Proto = buoy_node:object([]),
    methods(Proto, ?STATE, [{<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This), -1) end},
                    {<<"asyncReset">>, fun(This, _) -> update(This, fun(S) -> S#{async_id => new_async_id()} end) end},
                    {<<"getAsyncContextFrameForDebuggingOnly">>, fun(_, _) -> undefined end},
                    {<<"getProviderType">>, fun(This, _) -> maps:get(provider, state(This), 0) end}]),
    Proto.

%% The methods of a FunctionTemplate with a signature: another receiver is
%% an illegal invocation.
methods(Proto, Slot, Methods) ->
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, fun(This, Args) ->
                                         case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, Slot) of
                                             {ok, _} -> Fun(This, Args);
                                             _ -> buoy_heap:throw_error('TypeError', <<"Illegal invocation">>)
                                         end
                                     end),
                                     writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    ok.

%%% The parser

new(This) ->
    buoy_heap:private_put(This, ?STATE, fresh(#{})),
    undefined.

%% The per-message state that Init and on_message_begin reset.
fresh(S) ->
    S#{fields => [], values => [], url => <<>>, status => <<>>, header_nread => 0, chunk_extensions => 0,
       headers_completed => false, current => undefined}.

state(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        _ -> #{}
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

update(This, Fun) ->
    case state(This) of
        #{} = S when map_size(S) > 0 -> save(This, Fun(S));
        _ -> ok
    end,
    undefined.

with_parser(This, Fun) ->
    update(This, fun(#{ll := LL} = S) -> S#{ll := Fun(LL)}; (S) -> S end).

%% initialize(type, resource, maxHeaderSize, lenientFlags, connectionsList).
initialize(This, Args) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    Type = case trunc(buoy_ref:to_number(A(1))) of
        ?REQUEST -> request;
        _ -> response
    end,
    MaxHeaderSize = case A(3) of
        N when is_number(N), N > 0 -> trunc(N);
        _ -> max_http_header_size()
    end,
    Lenient = case A(4) of
        L when is_number(L) -> trunc(L);
        _ -> 0
    end,
    Connections = case A(5) of
        List when List =:= undefined; List =:= null -> undefined;
        List -> List
    end,
    Old = state(This),
    leave_list(This, Old),
    Provider = case Type of
        request -> provider(<<"HTTPINCOMINGMESSAGE">>);
        response -> provider(<<"HTTPCLIENTREQUEST">>)
    end,
    S = (fresh(Old))#{ll => buoy_llhttp:init(Type, Lenient), type => Type, max_header_size => MaxHeaderSize,
                       have_flushed => false, freed => false, closed => false, connections => Connections,
                       async_id => new_async_id(), provider => Provider, generation => erlang:unique_integer(),
                       last_message_start => case Connections of undefined -> 0; _ -> hrtime() end},
    save(This, S),
    join_list(This, S, [all, active]),
    undefined.

close(This) ->
    S = state(This),
    leave_list(This, S),
    update(This, fun(St) -> St#{closed => true} end).

%% remove(): the parser is being freed, so its callbacks stop.
remove(This) ->
    leave_list(This, state(This)),
    update(This, fun(St) -> St#{freed => true} end).

execute(This, View) ->
    case state(This) of
        #{ll := _, closed := false} = S -> run(This, S, buoy_node_encoding:view_bytes(View));
        _ -> undefined
    end.

finish(This) ->
    case state(This) of
        #{ll := _, closed := false} = S -> run(This, S, finish);
        _ -> undefined
    end.

%% Parser::Execute: the bytes parsed, an Error with bytesParsed, code, and
%% reason, or the exception of a callback, thrown again.
run(This, #{ll := LL, generation := Generation} = S, Data) ->
    erase_exception(This),
    Current = case Data of finish -> <<>>; _ -> Data end,
    save(This, S#{current => Current}),
    Cb = fun(Event) -> event(This, Event) end,
    {Status, LL1} = case Data of
        finish -> buoy_llhttp:finish(LL, Cb);
        _ -> buoy_llhttp:execute(LL, Data, Cb)
    end,
    S1 = state(This),
    %% llhttp_finish returns HPE_OK on a parser that has failed already.
    Error = case {Data, Status} of
        {finish, ok} -> ok;
        _ -> buoy_llhttp:error_of(LL1)
    end,
    {Result, LL2} = case Error of
        ok -> {ok, LL1};
        {<<"HPE_PAUSED_UPGRADE">>, _, Pos} -> {{nread, Pos}, buoy_llhttp:resume_after_upgrade(LL1)};
        {Code, Reason, Pos} -> {{error, Code, Reason, Pos}, LL1}
    end,
    %% A callback that initialized the parser again replaced its state.
    case S1 of
        #{generation := Generation} -> save(This, S1#{ll => keep_pause(maps:get(ll, S1), LL2), current => undefined});
        _ -> ok
    end,
    case take_exception(This) of
        {Class, Reason1, Stack} -> erlang:raise(Class, Reason1, Stack);
        none -> ok
    end,
    case {Result, Data} of
        {{error, ErrCode, ErrReason, ErrPos}, _} ->
            case buoy_llhttp:upgrade(LL2) of
                true -> nread(ErrPos, Data);
                false -> parse_error(ErrCode, ErrReason, ErrPos, Data)
            end;
        {_, finish} -> undefined;
        {{nread, Pos1}, _} -> Pos1;
        {ok, _} -> byte_size(Data)
    end.

nread(_, finish) -> undefined;
nread(Pos, _) -> Pos.

%% A pause() from a callback holds for the next call, as llhttp_pause sets the
%% error of the parser that the running llhttp_execute does not check.
keep_pause(During, After) ->
    case {buoy_llhttp:error_of(During), buoy_llhttp:error_of(After)} of
        {{<<"HPE_PAUSED">>, _, _}, ok} -> buoy_llhttp:pause(After);
        _ -> After
    end.

parse_error(Code, Reason, Pos, Data) ->
    E = buoy_heap:construct(buoy_ref_realm:global(<<"Error">>), [<<"Parse Error">>], buoy_ref_realm:global(<<"Error">>)),
    BytesParsed = case Data of finish -> 0; _ -> Pos end,
    [buoy_heap:set(E, K, V) || {K, V} <- [{<<"bytesParsed">>, BytesParsed}, {<<"code">>, Code}, {<<"reason">>, Reason}]],
    E.

%%% The callbacks of llhttp

event(This, Event) ->
    S = state(This),
    case maps:get(freed, S, false) orelse has_exception(This) of
        true -> skip(Event);
        false -> on(This, Event, S)
    end.

skip({headers_complete, _}) -> 0;
skip({_, Bytes}) when is_binary(Bytes) -> ok;
skip(_) -> 0.

on(This, message_begin, S) ->
    leave_list(This, S),
    S1 = (fresh(S))#{current => maps:get(current, S), last_message_start => hrtime()},
    save(This, S1),
    join_list(This, S1, [all, active]),
    call(This, ?K_ON_MESSAGE_BEGIN, []),
    0;
on(This, {url, Bytes}, S) ->
    track(This, S, Bytes, fun(S1) -> S1#{url := <<(maps:get(url, S1))/binary, Bytes/binary>>} end);
on(This, {status, Bytes}, S) ->
    track(This, S, Bytes, fun(S1) -> S1#{status := <<(maps:get(status, S1))/binary, Bytes/binary>>} end);
on(This, {header_field, Bytes}, S) ->
    track(This, S, Bytes, fun(S1) -> header_field(This, S1, Bytes) end);
on(This, {header_value, Bytes}, S) ->
    track(This, S, Bytes, fun(#{fields := Fields, values := Values} = S1) ->
        case length(Fields) =:= length(Values) of
            true -> S1#{values := [<<(hd(Values))/binary, Bytes/binary>> | tl(Values)]};
            false -> S1#{values := [Bytes | Values]}
        end
    end);
on(This, {headers_complete, Info}, S) ->
    headers_complete(This, S#{headers_completed := true, header_nread := 0}, Info);
on(_, {body, <<>>}, _) ->
    ok;
on(This, {body, Bytes}, _) ->
    case call(This, ?K_ON_BODY, [buoy_node_encoding:new_buffer(Bytes)]) of
        error -> {user, <<"HPE_JS_EXCEPTION">>, <<"JS Exception">>};
        _ -> ok
    end;
on(This, message_complete, S) ->
    leave_list(This, S),
    S1 = S#{last_message_start => 0},
    save(This, S1),
    join_list(This, S1, [all]),
    case maps:get(fields, S1) of
        [] -> ok;
        _ -> flush(This, S1)
    end,

    case call(This, ?K_ON_MESSAGE_COMPLETE, []) of
        error -> -1;
        _ -> 0
    end;
on(This, {chunk_extension, Bytes}, S) ->
    Total = maps:get(chunk_extensions, S) + byte_size(Bytes),
    save(This, S#{chunk_extensions := Total}),
    case Total > ?MAX_CHUNK_EXTENSIONS_SIZE of
        true -> {user, <<"HPE_CHUNK_EXTENSIONS_OVERFLOW">>, <<"Chunk extensions overflow">>};
        false -> ok
    end;
on(This, chunk_header, S) ->
    save(This, S#{header_nread := 0, chunk_extensions := 0}),
    0;
on(This, chunk_complete, S) ->
    save(This, S#{header_nread := 0}),
    0.

%% TrackHeader: the start line and the headers together stay under the
%% maximum size.
track(This, #{header_nread := Read, max_header_size := Max} = S, Bytes, Fun) ->
    Total = Read + byte_size(Bytes),
    case Total >= Max of
        true ->
            save(This, S#{header_nread := Total}),
            {user, <<"HPE_HEADER_OVERFLOW">>, <<"Header overflow">>};
        false ->
            save(This, Fun(S#{header_nread := Total})),
            ok
    end.

%% A new field once the last one has its value; past 31 pairs, the pairs so
%% far go to kOnHeaders first.
header_field(This, #{fields := Fields, values := Values} = S, Bytes) when length(Fields) =:= length(Values) ->
    case length(Fields) + 1 =:= ?MAX_HEADER_FIELDS of
        true ->
            S1 = flush(This, S),
            S1#{fields := [Bytes], values := []};
        false ->
            S#{fields := [Bytes | Fields]}
    end;
header_field(_, #{fields := [Field | Fields]} = S, Bytes) ->
    S#{fields := [<<Field/binary, Bytes/binary>> | Fields]}.

%% The pairs as kOnHeaders and kOnHeadersComplete take them: each value
%% without its trailing whitespace.
headers(#{fields := Fields, values := Values}) ->
    Pairs = lists:zip(lists:nthtail(length(Fields) - length(Values), lists:reverse(Fields)), lists:reverse(Values)),
    buoy_heap:new_array(lists:append([[F, trim(V)] || {F, V} <- Pairs])).

trim(V) -> string:trim(V, trailing, " \t").

%% Flush: spill the headers so far and the URL to kOnHeaders. Returns the
%% state after it.
flush(This, S) ->
    case is_callback(This, ?K_ON_HEADERS) of
        false ->
            S;
        true ->
            Headers = headers(S),
            save(This, S#{url := <<>>, have_flushed := true}),
            call(This, ?K_ON_HEADERS, [Headers, maps:get(url, S)]),
            state(This)
    end.

headers_complete(This, S, Info) ->
    case is_callback(This, ?K_ON_HEADERS_COMPLETE) of
        false ->
            save(This, S#{fields := [], values := []}),
            0;
        true ->
            Type = maps:get(type, S),
            {Headers, Url, S1} = case maps:get(have_flushed, S) of
                true -> {undefined, undefined, flush(This, S)};
                false when Type =:= request -> {headers(S), maps:get(url, S), S};
                false -> {headers(S), undefined, S}
            end,
            save(This, S1#{fields := [], values := []}),
            {Method, Status, Message} = case Type of
                request -> {maps:get(method, Info), undefined, undefined};
                response -> {undefined, maps:get(status, Info), maps:get(status, S)}
            end,
            Args = [maps:get(major, Info), maps:get(minor, Info), Headers, Method, Url, Status, Message,
                    maps:get(upgrade, Info), maps:get(keep_alive, Info)],
            case call(This, ?K_ON_HEADERS_COMPLETE, Args) of
                error -> -1;
                {ok, Result} -> to_integer(Result)
            end
    end.

to_integer(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        F when is_float(F) -> trunc(F);
        _ -> 0
    end.

is_callback(This, Key) ->
    buoy_heap:is_callable(buoy_heap:get(This, Key)).

%% Calls this[Key](...Args): {ok, Result}, skipped when it is no function,
%% or error when it throws, keeping the exception for execute() to throw.
call(This, Key, Args) ->
    F = buoy_heap:get(This, Key),
    case buoy_heap:is_callable(F) of
        false ->
            skipped;
        true ->
            try
                {ok, buoy_heap:call(F, This, Args)}
            catch
                Class:Reason:Stack ->
                    buoy_heap:private_put(This, {'#', ?MODULE, <<"exception">>}, {Class, Reason, Stack}),
                    error
            end
    end.

has_exception(This) ->
    case buoy_heap:private_find(This, {'#', ?MODULE, <<"exception">>}) of
        {ok, {_, _, _}} -> true;
        _ -> false
    end.

take_exception(This) ->
    case buoy_heap:private_find(This, {'#', ?MODULE, <<"exception">>}) of
        {ok, none} -> none;
        {ok, Exception} -> erase_exception(This), Exception;
        error -> none
    end.

erase_exception(This) ->
    buoy_heap:private_put(This, {'#', ?MODULE, <<"exception">>}, none).

current_buffer(This) ->
    case state(This) of
        #{current := Bytes} when is_binary(Bytes) -> buoy_node_encoding:new_buffer(Bytes);
        _ -> buoy_node_encoding:new_buffer(<<>>)
    end.

%%% ConnectionsList

connections_class() ->
    Class = buoy_node:constructor(<<"ConnectionsList">>, 0, fun(This, _) ->
        buoy_heap:private_put(This, ?LIST, #{all => [], active => []}),
        undefined
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    methods(Proto, ?LIST, [{<<"all">>, fun(This, _) -> listed(This, all) end},
                    {<<"idle">>, fun(This, _) -> buoy_heap:new_array([P || P <- sorted(This, all), start_of(P) =:= 0]) end},
                    {<<"active">>, fun(This, _) -> listed(This, active) end},
                    {<<"expired">>, fun(This, Args) -> expired(This, A(1, Args), A(2, Args)) end}]),
    Class.

list_state(List) ->
    case buoy_heap:is_object(List) andalso buoy_heap:private_find(List, ?LIST) of
        {ok, L} -> L;
        _ -> #{all => [], active => []}
    end.

join_list(This, #{connections := List}, Sets) when List =/= undefined ->
    L = list_state(List),
    buoy_heap:private_put(List, ?LIST, lists:foldl(fun(Set, Acc) ->
        Acc#{Set := (maps:get(Set, Acc) -- [This]) ++ [This]}
    end, L, Sets));
join_list(_, _, _) ->
    ok.

leave_list(This, #{connections := List}) when List =/= undefined ->
    L = list_state(List),
    buoy_heap:private_put(List, ?LIST, L#{all := maps:get(all, L) -- [This], active := maps:get(active, L) -- [This]});
leave_list(_, _) ->
    ok.

start_of(Parser) -> maps:get(last_message_start, state(Parser), 0).

%% The parsers in the order of std::set with ParserComparator: idle ones
%% first, then by the start of their current message.
sorted(List, Set) ->
    Keyed = [{start_of(P), I, P} || {I, P} <- lists:enumerate(maps:get(Set, list_state(List)))],
    [P || {_, _, P} <- lists:sort(Keyed)].

listed(List, Set) -> buoy_heap:new_array(sorted(List, Set)).

%% expired(headersTimeout, requestTimeout): the active parsers past a
%% deadline, which leave the active set.
expired(List, HeadersTimeout, RequestTimeout) ->
    H0 = to_integer(HeadersTimeout) * 1000000,
    R0 = to_integer(RequestTimeout) * 1000000,
    {H, R} = case R0 > 0 andalso H0 > R0 of
        true -> {R0, H0};
        false -> {H0, R0}
    end,
    Now = hrtime(),
    HeadersDeadline = case H > 0 andalso Now > H of true -> Now - H; false -> 0 end,
    RequestDeadline = case R > 0 andalso Now > R of true -> Now - R; false -> 0 end,
    case {H0, R0, HeadersDeadline, RequestDeadline} of
        {0, 0, _, _} -> buoy_heap:new_array([]);
        {_, _, 0, 0} -> buoy_heap:new_array([]);
        _ ->
            Expired = [P || P <- sorted(List, active),
                            begin
                                S = state(P),
                                Start = maps:get(last_message_start, S, 0),
                                (not maps:get(headers_completed, S, false) andalso HeadersDeadline > 0
                                 andalso Start < HeadersDeadline)
                                    orelse (RequestDeadline > 0 andalso Start < RequestDeadline)
                            end],
            L = list_state(List),
            buoy_heap:private_put(List, ?LIST, L#{active := maps:get(active, L) -- Expired}),
            buoy_heap:new_array(Expired)
    end.

%%% Helpers

%% uv_hrtime: nanoseconds from an origin far enough back that a deadline of
%% any timeout is positive, as the uptime of the machine makes it in libuv.
hrtime() ->
    Start = erlang:convert_time_unit(erlang:system_info(start_time), native, nanosecond),
    erlang:monotonic_time(nanosecond) - Start + (1 bsl 50).

provider(Name) ->
    Providers = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"Providers">>),
    buoy_heap:get(Providers, Name).

new_async_id() ->
    Fields = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"async_id_fields">>),
    Id = buoy_heap:get(Fields, 2) + 1,
    buoy_heap:set(Fields, 2, Id),
    Id.

%% --max-http-header-size of the options, read once per realm.
max_http_header_size() ->
    case erlang:get(?MAX_HEADER_SIZE) of
        undefined ->
            Options = buoy_node:binding(<<"options">>),
            Values = buoy_heap:call(buoy_heap:get(Options, <<"getCLIOptionsValues">>), Options, []),
            Size = case buoy_heap:get(Values, <<"--max-http-header-size">>) of
                N when is_number(N) -> trunc(N);
                _ -> 16384
            end,
            erlang:put(?MAX_HEADER_SIZE, Size),
            Size;
        Size ->
            Size
    end.
