%% internalBinding('zlib') (src/node_zlib.cc): the classes Zlib, BrotliEncoder,
%% BrotliDecoder, ZstdCompress, and ZstdDecompress, whose handles are Node's
%% CompressionStream, and crc32.
%%
%% The codecs are the NIFs of buoy_native, which run a write on a dirty CPU
%% scheduler. write/7 runs the codec in a process of its own and reports the
%% result to the write callback in a later macrotask, as libuv calls back from
%% its thread pool; writeSync/7 reports it before it returns.
-module(buoy_binding_zlib).

-include("buoy_ref.hrl").

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
%% A param that lib/zlib.js leaves unset: -1 in its Uint32Array.
-define(UNSET, 16#FFFFFFFF).

-type kind() :: zlib | brotli_encoder | brotli_decoder | zstd_compress | zstd_decompress.

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"Zlib">>, class(<<"Zlib">>, zlib)},
        {<<"BrotliEncoder">>, class(<<"BrotliEncoder">>, brotli_encoder)},
        {<<"BrotliDecoder">>, class(<<"BrotliDecoder">>, brotli_decoder)},
        {<<"ZstdCompress">>, class(<<"ZstdCompress">>, zstd_compress)},
        {<<"ZstdDecompress">>, class(<<"ZstdDecompress">>, zstd_decompress)},
        {<<"crc32">>, F(<<"crc32">>, 2, fun(_, Args) -> crc32(buoy_node:arg(1, Args), buoy_node:arg(2, Args)) end)}]).

%% A class whose instances are handles of Kind, with the methods of
%% MakeClass in node_zlib.cc.
-spec class(binary(), kind()) -> term().
class(Name, Kind) ->
    Class = buoy_node:constructor(Name, 1, fun(This, Args) -> construct(This, Kind, Args) end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    Methods = [
        {<<"write">>, 7, fun(This, Args) -> write(This, Args, async) end},
        {<<"writeSync">>, 7, fun(This, Args) -> write(This, Args, sync) end},
        {<<"close">>, 0, fun(This, _) -> close(This) end},
        {<<"init">>, 7, fun(This, Args) -> init(This, Args) end},
        {<<"params">>, 2, fun(This, Args) -> params(This, A(1, Args), A(2, Args)) end},
        {<<"reset">>, 0, fun(This, _) -> reset(This) end},
        {<<"getAsyncId">>, 0, fun(_, _) -> erlang:unique_integer([positive]) end}],
    [buoy_heap:define(Proto, Method, #{value => buoy_node:fn(Method, Length, Fun), writable => true,
                                       enumerable => true, configurable => true})
     || {Method, Length, Fun} <- Methods],
    Class.

construct(This, Kind, Args) ->
    Mode = case Kind of
        zlib -> int32(buoy_node:arg(1, Args));
        _ -> none
    end,
    save(This, #{kind => Kind, mode => Mode, stream => none, write_in_progress => false,
                 pending_close => false, write_result => undefined, callback => undefined}),
    undefined.

state(This) ->
    case buoy_heap:private_find(This, ?STATE) of
        {ok, State} -> State;
        error -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_THIS">>, <<"Illegal invocation">>)
    end.

save(This, State) -> buoy_heap:private_put(This, ?STATE, State).

%%% init

%% ZlibStream::Init(windowBits, level, memLevel, strategy, writeResult,
%% writeCallback, dictionary), BrotliCompressionStream::Init(params,
%% writeResult, writeCallback[, dictionary]), and ZstdStream::Init(params,
%% pledgedSrcSize, writeResult, writeCallback[, dictionary]).
init(This, Args) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    State = state(This),
    case maps:get(kind, State) of
        zlib ->
            Dictionary = case is_view(A(7)) of
                true -> buoy_node_encoding:view_bytes(A(7));
                false -> <<>>
            end,
            Stream = buoy_native:zlib_open(maps:get(mode, State), int32(A(2)), uint32(A(1)),
                                           uint32(A(3)), uint32(A(4)), Dictionary),
            save(This, State#{stream => Stream, write_result => A(5), callback => A(6)});
        Kind when Kind =:= brotli_encoder; Kind =:= brotli_decoder ->
            save(This, State#{write_result => A(2), callback => A(3)}),
            Stream = buoy_native:brotli_open(Kind =:= brotli_encoder, dictionary(A(4))),
            save(This, (state(This))#{stream => Stream}),
            set_parameters(This, Stream, A(1), fun(_) -> <<"Initialization failed">> end);
        Kind ->
            save(This, State#{write_result => A(3), callback => A(4)}),
            Pledged = pledged_src_size(A(2)),
            case buoy_native:zstd_open(Kind =:= zstd_compress, Pledged, dictionary(A(5))) of
                {ok, Stream} ->
                    save(This, (state(This))#{stream => Stream}),
                    set_parameters(This, Stream, A(1), fun({Message, _, _}) -> Message end);
                {error, {Message, _, _} = Failure} ->
                    emit_error(This, Failure),
                    initialization_failed(Message)
            end
    end,
    undefined.

%% The params that lib/zlib.js set, in the order of their keys. A param that
%% the codec rejects reaches onerror, then throws.
set_parameters(This, Stream, Params, MessageOf) ->
    Values = [V || <<V:32/little>> <= buoy_node_encoding:view_bytes(Params)],
    lists:foldl(
        fun(?UNSET, Key) -> Key + 1;
           (Value, Key) ->
                case buoy_native:stream_set_parameter(Stream, Key, Value) of
                    nil -> Key + 1;
                    Failure ->
                        emit_error(This, Failure),
                        initialization_failed(MessageOf(Failure))
                end
        end, 0, Values),
    ok.

-spec initialization_failed(binary()) -> no_return().
initialization_failed(Message) ->
    buoy_node:throw_code('Error', <<"ERR_ZLIB_INITIALIZATION_FAILED">>, Message).

dictionary(undefined) -> <<>>;
dictionary(View) ->
    case is_view(View) of
        true -> buoy_node_encoding:view_bytes(View);
        false -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                      <<"dictionary must be an ArrayBufferView if provided">>)
    end.

%% A number gives the pledged size of the frame; anything else leaves it
%% unknown.
pledged_src_size(Value) when ?IS_NUMBER(Value) ->
    case buoy_ref_number:to_integer_or_infinity(Value) of
        Size when is_integer(Size), Size >= 0 -> Size;
        Size when is_integer(Size) ->
            buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_VALUE">>, <<"pledgedSrcSize may not be negative">>);
        _ ->
            buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_VALUE">>, <<"pledgedSrcSize should be an integer">>)
    end;
pledged_src_size(_) -> -1.

%%% write

%% CompressionStream::Write(flush, in, in_off, in_len, out, out_off, out_len).
write(This, Args, Mode) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    State = state(This),
    #{stream := Stream} = State,
    (Stream =:= none orelse maps:get(write_in_progress, State) orelse maps:get(pending_close, State))
        andalso buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>, <<"zlib handle cannot write">>),
    Input = case A(2) of
        null -> <<>>;
        In -> InOff = uint32(A(3)), buoy_node_encoding:view_bytes(In, InOff, InOff + uint32(A(4)))
    end,
    Out = A(5),
    OutOff = uint32(A(6)),
    save(This, State#{write_in_progress => true}),
    Flush = uint32(A(1)),
    OutLen = uint32(A(7)),
    case Mode of
        sync ->
            {Bytes, AvailIn, AvailOut, Failure} = buoy_native:stream_write(Stream, Flush, Input, OutLen),
            buoy_node_encoding:view_write(Out, OutOff, Bytes),
            after_write_sync(This, AvailIn, AvailOut, Failure);
        async ->
            start_write(This, Out, OutOff, fun() -> buoy_native:stream_write(Stream, Flush, Input, OutLen) end)
    end,
    undefined.

%% Runs a write in a process of its own, as Node runs it on the libuv thread
%% pool, so the realm runs JavaScript meanwhile. The realm keeps the handle
%% and the output buffer as roots of its heap until the result arrives.
start_write(This, Out, OutOff, Write) ->
    Realm = self(),
    Key = {?MODULE, write, make_ref()},
    erlang:put(Key, {This, Out}),
    buoy_node_loop:ref_handle(),
    {Traced, Finished} = buoy_trace:pool_work(<<"zlib">>, Write),
    _ = spawn(fun() ->
        Result = try {ok, Traced()} catch Class:Reason:Stack -> {raised, Class, Reason, Stack} end,
        Realm ! {'$buoy_node_call', fun() -> Finished(), finish_write(Key, OutOff, Result) end}
    end),
    ok.

finish_write(Key, OutOff, Result) ->
    {This, Out} = erlang:erase(Key),
    buoy_node_loop:unref_handle(),
    case Result of
        {ok, {Bytes, AvailIn, AvailOut, Failure}} ->
            buoy_node_encoding:view_write(Out, OutOff, Bytes),
            after_write(This, AvailIn, AvailOut, Failure);
        {raised, Class, Reason, Stack} ->
            erlang:raise(Class, Reason, Stack)
    end.

after_write_sync(This, _AvailIn, _AvailOut, {_, _, _} = Failure) ->
    emit_error(This, Failure);
after_write_sync(This, AvailIn, AvailOut, nil) ->
    State = state(This),
    update_write_result(State, AvailIn, AvailOut),
    save(This, State#{write_in_progress => false}).

%% AfterThreadPoolWork: the result, then the write callback, then a close
%% that waited for the write.
after_write(This, _AvailIn, _AvailOut, {_, _, _} = Failure) ->
    save(This, (state(This))#{write_in_progress => false}),
    emit_error(This, Failure);
after_write(This, AvailIn, AvailOut, nil) ->
    State = state(This),
    save(This, State#{write_in_progress => false}),
    update_write_result(State, AvailIn, AvailOut),
    buoy_heap:call(maps:get(callback, State), This, []),
    maps:get(pending_close, state(This)) andalso close(This),
    ok.

%% writeResult holds [availOutAfter, availInAfter].
update_write_result(#{write_result := Result}, AvailIn, AvailOut) ->
    buoy_node_encoding:view_write(Result, 0, <<AvailOut:32/little, AvailIn:32/little>>).

%% EmitError: onerror(message, errno, code), then a close that waited.
emit_error(This, {Message, Errno, Code}) ->
    OnError = buoy_heap:get(This, <<"onerror">>),
    buoy_heap:is_callable(OnError) andalso
        buoy_heap:call(OnError, This, [buoy_node:string(Message), Errno, buoy_node:string(Code)]),
    State = state(This),
    save(This, State#{write_in_progress => false}),
    maps:get(pending_close, State) andalso close(This),
    ok.

%%% close, reset, params

close(This) ->
    State = state(This),
    case State of
        #{write_in_progress := true} ->
            save(This, State#{pending_close => true});
        #{stream := none} ->
            save(This, State#{pending_close => false});
        #{stream := Stream} ->
            buoy_native:stream_close(Stream),
            save(This, State#{pending_close => false})
    end,
    undefined.

reset(This) ->
    State = state(This),
    maps:get(write_in_progress, State) andalso
        buoy_heap:throw_error('Error', <<"Cannot reset zlib stream while a write is in progress">>),
    Stream = maps:get(stream, State),
    Stream =/= none andalso report(This, buoy_native:stream_reset(Stream)),
    undefined.

%% ZlibStream::Params; brotli and zstd take none.
params(This, Level, Strategy) ->
    case state(This) of
        #{kind := zlib, stream := Stream} when Stream =/= none ->
            report(This, buoy_native:stream_params(Stream, int32(Level), int32(Strategy)));
        _ ->
            ok
    end,
    undefined.

report(_This, nil) -> ok;
report(This, Failure) -> emit_error(This, Failure).

%%% crc32

%% crc32(data, value): the CRC-32 of zlib, of a string's UTF-8 bytes.
crc32(Data, Value) ->
    Bytes = case is_view(Data) of
        true -> buoy_node_encoding:view_bytes(Data);
        false -> buoy_ref_string:to_utf8(buoy_ref:to_string(Data))
    end,
    erlang:crc32(uint32(Value), Bytes).

%%% Values

is_view(V) ->
    ?IS_OBJECT(V) andalso lists:member(buoy_heap:class_of(V), [typed_array, data_view]).

uint32(V) -> buoy_ref_number:to_uint32(buoy_ref:to_number(V)).

int32(V) -> buoy_ref_number:to_int32(buoy_ref:to_number(V)).
