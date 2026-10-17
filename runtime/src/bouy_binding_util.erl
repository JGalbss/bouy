%% internalBinding('util') (src/node_util.cc): the private symbols, the
%% constants of promise states, exit fields, and property filters, and the
%% introspection that util.inspect and the loaders need.
-module(bouy_binding_util).

-include("bouy_ref.hrl").

-export([binding/0]).

-define(ONLY_ENUMERABLE, 2).
-define(SKIP_STRINGS, 8).
-define(SKIP_SYMBOLS, 16).

-spec binding() -> term().
binding() ->
    Constants = bouy_node:object([
        {<<"kPending">>, 0}, {<<"kFulfilled">>, 1}, {<<"kRejected">>, 2},
        {<<"kExiting">>, 0}, {<<"kExitCode">>, 1}, {<<"kHasExitCode">>, 2},
        {<<"ALL_PROPERTIES">>, 0}, {<<"ONLY_WRITABLE">>, 1}, {<<"ONLY_ENUMERABLE">>, ?ONLY_ENUMERABLE},
        {<<"ONLY_CONFIGURABLE">>, 4}, {<<"SKIP_STRINGS">>, ?SKIP_STRINGS}, {<<"SKIP_SYMBOLS">>, ?SKIP_SYMBOLS},
        {<<"kDisallowCloneAndTransfer">>, 0}, {<<"kTransferable">>, 1}, {<<"kCloneable">>, 2}]),
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"privateSymbols">>, bouy_node:private_symbols()},
        {<<"constants">>, Constants},
        {<<"isInsideNodeModules">>, F(<<"isInsideNodeModules">>, 0, fun(_, _) -> false end)},
        {<<"defineLazyProperties">>, F(<<"defineLazyProperties">>, 4, fun(_, A) -> define_lazy(A) end)},
        {<<"getPromiseDetails">>, F(<<"getPromiseDetails">>, 1, fun(_, A) -> promise_details(bouy_node:arg(1, A)) end)},
        {<<"getProxyDetails">>, F(<<"getProxyDetails">>, 1, fun(_, A) -> proxy_details(bouy_node:arg(1, A), bouy_node:arg(2, A)) end)},
        {<<"getCallerLocation">>, F(<<"getCallerLocation">>, 0, fun(_, _) -> undefined end)},
        {<<"previewEntries">>, F(<<"previewEntries">>, 2, fun(_, A) -> preview_entries(bouy_node:arg(1, A), bouy_node:arg(2, A)) end)},
        {<<"getOwnNonIndexProperties">>, F(<<"getOwnNonIndexProperties">>, 2, fun(_, A) ->
            own_non_index(bouy_node:arg(1, A), bouy_node:arg(2, A))
        end)},
        {<<"getConstructorName">>, F(<<"getConstructorName">>, 1, fun(_, A) -> constructor_name(bouy_node:arg(1, A)) end)},
        {<<"getExternalValue">>, F(<<"getExternalValue">>, 1, fun(_, _) -> {'$bigint', 0} end)},
        {<<"getCallSites">>, F(<<"getCallSites">>, 1, fun(_, _) -> bouy_heap:new_array([]) end)},
        {<<"sleep">>, F(<<"sleep">>, 1, fun(_, A) -> timer:sleep(trunc(bouy_ref:to_number(bouy_node:arg(1, A)))), undefined end)},
        {<<"parseEnv">>, F(<<"parseEnv">>, 1, fun(_, A) -> parse_env(bouy_node:arg(1, A)) end)},
        {<<"arrayBufferViewHasBuffer">>, F(<<"arrayBufferViewHasBuffer">>, 1, fun(_, _) -> true end)},
        {<<"constructSharedArrayBuffer">>, F(<<"constructSharedArrayBuffer">>, 1, fun(_, A) ->
            C = bouy_ref_realm:global(<<"SharedArrayBuffer">>),
            bouy_heap:construct(C, [bouy_node:arg(1, A)], C)
        end)},
        {<<"shouldAbortOnUncaughtToggle">>, bouy_node:typed_array(<<"Uint32Array">>, 1)},
        {<<"guessHandleType">>, F(<<"guessHandleType">>, 1, fun(_, A) -> handle_type(bouy_node:arg(1, A)) end)},
        {<<"isConstructor">>, F(<<"isConstructor">>, 1, fun(_, A) -> bouy_heap:is_constructor(bouy_node:arg(1, A)) end)}
    ] ++ bouy_binding_types:checks([<<"isArrayBuffer">>, <<"isAsyncFunction">>, <<"isDataView">>, <<"isDate">>,
                                     <<"isExternal">>, <<"isMap">>, <<"isMapIterator">>, <<"isNativeError">>,
                                     <<"isPromise">>, <<"isRegExp">>, <<"isSet">>, <<"isSetIterator">>,
                                     <<"isAnyArrayBuffer">>])
      ++ [{<<"isArrayBufferView">>, F(<<"isArrayBufferView">>, 1, fun(_, A) -> is_view(bouy_node:arg(1, A)) end)},
          {<<"isTypedArray">>, F(<<"isTypedArray">>, 1, fun(_, A) -> class(bouy_node:arg(1, A)) =:= typed_array end)},
          {<<"isUint8Array">>, F(<<"isUint8Array">>, 1, fun(_, A) -> is_uint8(bouy_node:arg(1, A)) end)}]).

class(V) when ?IS_OBJECT(V) -> bouy_heap:class_of(V);
class(_) -> none.

is_view(V) -> lists:member(class(V), [typed_array, data_view]).

is_uint8(V) ->
    class(V) =:= typed_array andalso element(1, bouy_heap:slots(V)) =:= uint8.

%% defineLazyProperties(target, id, keys, enumerable = true): each key reads
%% require(id)[key] on first access and then holds the value.
define_lazy(Args) ->
    Target = bouy_node:arg(1, Args),
    Id = bouy_node:arg(2, Args),
    Keys = bouy_heap:array_items(bouy_node:arg(3, Args)),
    Enumerable = case bouy_node:arg(4, Args) of
        undefined -> true;
        E -> bouy_ref:truthy(E)
    end,
    lists:foreach(fun(Key) ->
        Settle = fun(Value) ->
            bouy_heap:define(Target, Key, #{value => Value, writable => true, enumerable => Enumerable, configurable => true}),
            Value
        end,
        Get = bouy_node:fn(<<"get">>, 0, fun(_, _) ->
            {_, Require} = bouy_node:loaders(),
            Settle(bouy_heap:get(bouy_heap:call(Require, null, [Id]), Key))
        end),
        Set = bouy_node:fn(<<"set">>, 1, fun(_, A) -> Settle(bouy_node:arg(1, A)), undefined end),
        bouy_heap:define(Target, Key, #{get => Get, set => Set, enumerable => Enumerable, configurable => true})
    end, Keys),
    undefined.

promise_details(P) ->
    case class(P) of
        promise ->
            case bouy_heap:slots(P) of
                {pending, _, _, _} -> bouy_heap:new_array([0]);
                {fulfilled, V, _} -> bouy_heap:new_array([1, V]);
                {rejected, R, _} -> bouy_heap:new_array([2, R])
            end;
        _ ->
            undefined
    end.

proxy_details(P, ShowProxy) ->
    case class(P) of
        proxy ->
            {Target, Handler} = case bouy_heap:slots(P) of
                {revoked, _} -> {null, null};
                TH -> TH
            end,
            case ShowProxy of
                false -> Target;
                _ -> bouy_heap:new_array([Target, Handler])
            end;
        _ ->
            undefined
    end.

%% previewEntries(value, isIterator): the entries that a Map or Set iterator
%% has yet to give, flat as [key, value, ...] for a key-value iterator.
preview_entries(V, IsIterator) ->
    {Items, KeyValue} = case class(V) of
        C when C =:= map_iterator; C =:= set_iterator ->
            {_, Remaining} = bouy_ref_collection:remaining(V),
            Pairs = [I || I <- Remaining, is_list(I)],
            case Pairs =/= [] andalso length(Pairs) =:= length(Remaining) of
                true -> {lists:append(Pairs), true};
                false -> {Remaining, false}
            end;
        _ ->
            {[], false}
    end,
    Entries = bouy_heap:new_array(Items),
    case bouy_ref:truthy(IsIterator) of
        true -> bouy_heap:new_array([Entries, KeyValue]);
        false -> Entries
    end.

own_non_index(O, Filter) ->
    Bits = trunc(bouy_ref:to_number(Filter)),
    Keys = [K || K <- bouy_heap:own_keys(O), not is_integer(K), not is_index(K)],
    Kept = [K || K <- Keys,
                 Bits band ?ONLY_ENUMERABLE =:= 0 orelse bouy_heap:is_enumerable(bouy_heap:get_own(O, K)),
                 Bits band ?SKIP_SYMBOLS =:= 0 orelse not is_symbol(K),
                 Bits band ?SKIP_STRINGS =:= 0 orelse is_symbol(K)],
    bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- Kept]).

is_symbol(K) -> is_tuple(K) andalso element(1, K) =:= '$sym'.

%% A canonical array index in string form, for objects that keep such keys
%% as strings.
is_index(K) when is_binary(K), byte_size(K) > 0 ->
    case K of
        <<"0">> -> true;
        <<C, _/binary>> when C >= $1, C =< $9 -> lists:all(fun(D) -> D >= $0 andalso D =< $9 end, binary_to_list(K))
                                                      andalso binary_to_integer(K) < 4294967295;
        _ -> false
    end;
is_index(_) -> false.

%% V8's GetConstructorName: the name of the constructor of the first object
%% of the prototype chain that has one.
constructor_name(O) when ?IS_OBJECT(O) ->
    constructor_name(O, 0);
constructor_name(_) ->
    <<"Object">>.

constructor_name(_, 1000) ->
    <<"Object">>;
constructor_name(O, Depth) ->
    Found = case bouy_heap:get_own(O, <<"constructor">>) of
        {data, C, _} when ?IS_OBJECT(C) ->
            case bouy_heap:get(C, <<"name">>) of
                Name when ?IS_STRING(Name), Name =/= <<>> -> {ok, Name};
                _ -> none
            end;
        _ ->
            none
    end,
    case Found of
        {ok, N} ->
            N;
        none ->
            case bouy_heap:prototype_of(O) of
                null -> <<"Object">>;
                P -> constructor_name(P, Depth + 1)
            end
    end.

%% guessHandleType(fd): the index of the type in the handleTypes of
%% internal/util (TCP, TTY, UDP, FILE, PIPE, UNKNOWN). Stdio reads as a file,
%% so that process.stdout is a SyncWriteStream, unless the VM's device is a
%% terminal.
handle_type(Fd) ->
    case bouy_ref:to_number(Fd) of
        N when N =:= 0; N =:= 1; N =:= 2 ->
            Device = case N of 2 -> standard_error; _ -> standard_io end,
            case try io:getopts(Device) catch _:_ -> error end of
                Options when is_list(Options) ->
                    case proplists:get_value(terminal, Options, false) of
                        true -> 1;
                        _ -> 3
                    end;
                _ ->
                    3
            end;
        N when is_integer(N), N > 2 ->
            3;
        _ ->
            5
    end.

%% parseEnv(content): the variables of a dotenv text, as Node's Dotenv
%% parses them: KEY=value lines, an optional `export `, quotes, and comments.
parse_env(Content) ->
    Text = bouy_ref_string:to_utf8(bouy_ref:to_string(Content)),
    Lines = binary:split(binary:replace(Text, <<"\r\n">>, <<"\n">>, [global]), <<"\n">>, [global]),
    bouy_node:object(lists:reverse(lists:foldl(fun parse_env_line/2, [], Lines))).

parse_env_line(Line, Acc) ->
    Trimmed = string:trim(Line),
    Unexported = case Trimmed of
        <<"export ", Rest/binary>> -> string:trim(Rest);
        _ -> Trimmed
    end,
    case Unexported of
        <<"#", _/binary>> -> Acc;
        <<>> -> Acc;
        _ ->
            case binary:split(Unexported, <<"=">>) of
                [Key, Value] ->
                    Name = string:trim(Key),
                    [{bouy_ref_string:from_utf8(Name), bouy_ref_string:from_utf8(env_value(string:trim(Value)))}
                     | lists:keydelete(bouy_ref_string:from_utf8(Name), 1, Acc)];
                _ ->
                    Acc
            end
    end.

env_value(<<Q, Rest/binary>>) when Q =:= $"; Q =:= $'; Q =:= $` ->
    case binary:split(Rest, <<Q>>) of
        [Inner, _] when Q =:= $" -> binary:replace(Inner, <<"\\n">>, <<"\n">>, [global]);
        [Inner, _] -> Inner;
        [_] -> <<Q, Rest/binary>>
    end;
env_value(Value) ->
    case binary:split(Value, <<" #">>) of
        [Before, _] -> string:trim(Before);
        [_] -> Value
    end.
