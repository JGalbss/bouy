%% The String family: the String function and its statics, and
%% String.prototype.
-module(bouy_ref_string).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'String.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"String.prototype">>, string_methods()) ++ [{<<"constructor">>, constructor()}, {?SYM(iterator), builtin(<<"String.prototype[Symbol.iterator]">>, fun(This, _) -> bouy_ref_iterator:list_iterator(<<"String Iterator">>, [<<C/utf8>> || <<C/utf8>> <= This]) end)}], none)},
     {{builtin, <<"String">>}, ctor_record(<<"String">>, 1, {'$o', 'String.prototype'}, ?METHODS(<<"String">>, [<<"fromCharCode">>, <<"fromCodePoint">>]), fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"String">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"String">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"String">>, _This, []) -> <<>>;
call_constructor(<<"String">>, _This, [{'$sym', _, _} = S | _]) -> bouy_ref:describe(S);
call_constructor(<<"String">>, _This, [V | _]) -> bouy_ref:to_string(V).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"String.prototype">>, Name, This, Args) -> string_proto(Name, This, Args);
method(<<"String">>, Name, _This, Args) -> bouy_string:(binary_to_existing_atom(Name))([bouy_ref:to_number(A) || A <- Args]).

string_methods() ->
    [<<"at">>, <<"charAt">>, <<"charCodeAt">>, <<"codePointAt">>, <<"concat">>, <<"endsWith">>, <<"includes">>, <<"indexOf">>,
     <<"lastIndexOf">>, <<"localeCompare">>, <<"padEnd">>, <<"padStart">>, <<"repeat">>, <<"replace">>, <<"replaceAll">>,
     <<"slice">>, <<"split">>, <<"startsWith">>, <<"substring">>, <<"substr">>, <<"toLowerCase">>, <<"toUpperCase">>,
     <<"toLocaleLowerCase">>, <<"toLocaleUpperCase">>, <<"toString">>, <<"valueOf">>, <<"trim">>, <<"trimStart">>,
     <<"trimEnd">>, <<"normalize">>].

%% The value core implements the string methods; a callback becomes a value
%% fun and an array result becomes a heap array.
string_proto(Name, S, Args) when is_binary(S) ->
    Converted = [value_arg(A) || A <- Args],
    from_value(bouy_string:call(Name, S, Converted));
string_proto(Name, S, Args) ->
    string_proto(Name, bouy_ref:to_string(S), Args).

value_arg({'$f', _, _} = F) -> fun(CallArgs) -> bouy_ref:call(F, undefined, CallArgs) end;
value_arg(V) -> V.

from_value(L) when is_list(L) -> bouy_heap:new_array(L);
from_value(V) -> V.
