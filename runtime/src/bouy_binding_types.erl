%% internalBinding('types') (src/node_types.cc): the checks of util.types that
%% need the internal class of an object, which only the engine knows.
-module(bouy_binding_types).

-include("bouy_ref.hrl").

-export([binding/0, checks/1, check/2]).

-spec binding() -> term().
binding() ->
    bouy_node:object(checks([<<"isExternal">>, <<"isDate">>, <<"isArgumentsObject">>, <<"isBigIntObject">>,
                             <<"isBooleanObject">>, <<"isNumberObject">>, <<"isStringObject">>,
                             <<"isSymbolObject">>, <<"isNativeError">>, <<"isRegExp">>, <<"isAsyncFunction">>,
                             <<"isGeneratorFunction">>, <<"isGeneratorObject">>, <<"isPromise">>, <<"isMap">>,
                             <<"isSet">>, <<"isMapIterator">>, <<"isSetIterator">>, <<"isWeakMap">>,
                             <<"isWeakSet">>, <<"isArrayBuffer">>, <<"isDataView">>, <<"isSharedArrayBuffer">>,
                             <<"isProxy">>, <<"isModuleNamespaceObject">>, <<"isAnyArrayBuffer">>,
                             <<"isBoxedPrimitive">>])).

%% The functions of the checks Names.
-spec checks([binary()]) -> [{binary(), term()}].
checks(Names) ->
    [{Name, bouy_node:fn(Name, 0, fun(_, Args) -> check(Name, bouy_node:arg(1, Args)) end)} || Name <- Names].

-spec check(binary(), term()) -> boolean().
check(Name, V) when ?IS_OBJECT(V) ->
    Class = bouy_heap:class_of(V),
    is(Name, Class, V);
check(_Name, _V) ->
    false.

is(<<"isExternal">>, _, _) -> false;
is(<<"isDate">>, Class, _) -> Class =:= date;
is(<<"isArgumentsObject">>, Class, _) -> Class =:= arguments;
is(<<"isBigIntObject">>, Class, _) -> Class =:= bigint;
is(<<"isBooleanObject">>, Class, _) -> Class =:= boolean;
is(<<"isNumberObject">>, Class, _) -> Class =:= number;
is(<<"isStringObject">>, Class, _) -> Class =:= string;
is(<<"isSymbolObject">>, Class, _) -> Class =:= symbol;
is(<<"isNativeError">>, Class, _) -> Class =:= error;
is(<<"isRegExp">>, Class, _) -> Class =:= regexp;
is(<<"isAsyncFunction">>, function, V) -> lists:member(kind(V), [async, async_generator]);
is(<<"isGeneratorFunction">>, function, V) -> lists:member(kind(V), [generator, async_generator]);
is(<<"isGeneratorObject">>, Class, _) -> Class =:= generator orelse Class =:= async_generator;
is(<<"isPromise">>, Class, _) -> Class =:= promise;
is(<<"isMap">>, Class, _) -> Class =:= map;
is(<<"isSet">>, Class, _) -> Class =:= set;
is(<<"isMapIterator">>, Class, _) -> Class =:= map_iterator;
is(<<"isSetIterator">>, Class, _) -> Class =:= set_iterator;
is(<<"isWeakMap">>, Class, _) -> Class =:= weakmap;
is(<<"isWeakSet">>, Class, _) -> Class =:= weakset;
is(<<"isArrayBuffer">>, Class, _) -> Class =:= array_buffer;
is(<<"isDataView">>, Class, _) -> Class =:= data_view;
is(<<"isSharedArrayBuffer">>, Class, _) -> Class =:= shared_array_buffer;
is(<<"isProxy">>, Class, _) -> Class =:= proxy;
is(<<"isModuleNamespaceObject">>, Class, _) -> Class =:= namespace orelse Class =:= deferred_namespace;
is(<<"isAnyArrayBuffer">>, Class, _) -> Class =:= array_buffer orelse Class =:= shared_array_buffer;
is(<<"isBoxedPrimitive">>, Class, _) -> lists:member(Class, [number, string, boolean, bigint, symbol]);
is(_, _, _) -> false.

kind(F) ->
    case bouy_heap:slots(F) of
        #{kind := Kind} -> Kind;
        _ -> normal
    end.
