%% The Error family: Error, its native subclasses, AggregateError, and
%% Error.prototype.toString.
-module(bouy_ref_error).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, error_to_string/1]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-define(NAMES, [<<"Error">>, <<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"AggregateError">>]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Subclasses = [<<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"DataCloneError">>, <<"AggregateError">>],
    [{'Error.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Error.prototype">>, [<<"toString">>]) ++ [{<<"name">>, <<"Error">>}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(<<"Error">>)}], none)}]
    ++ [{binary_to_atom(<<N/binary, ".prototype">>), record(object, {'$o', 'Error.prototype'}, [{<<"name">>, N}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(N)}], none)} || N <- Subclasses]
    ++ [{{builtin, N}, ctor_record(N, 1, {'$o', binary_to_atom(<<N/binary, ".prototype">>)}, ?METHODS(N, [<<"captureStackTrace">>]), fun(NT, Args) -> error_construct(N, NT, Args) end)} || N <- ?NAMES].

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> bouy_ref_realm:constructor(?MODULE, Name).

%% An error constructor called without new constructs.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(Name, _This, Args) -> error_construct(Name, constructor(Name), Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Error.prototype">>, <<"toString">>, This, _) -> error_to_string(This);
method(_ErrorName, <<"captureStackTrace">>, _This, _Args) -> undefined.

error_construct(Name, NewTarget, Args) ->
    Proto = case NewTarget of
        {'$f', {builtin, _}, _} -> {'$o', binary_to_atom(<<Name/binary, ".prototype">>)};
        _ -> bouy_ref:get(NewTarget, <<"prototype">>)
    end,
    {MessageArg, OptionsArg} = case Name of
        <<"AggregateError">> -> {arg(2, Args), arg(3, Args)};
        _ -> {arg(1, Args), arg(2, Args)}
    end,
    Message = case MessageArg of
        undefined -> undefined;
        M -> bouy_ref:to_string(M)
    end,
    Header = case Message of
        undefined -> Name;
        <<>> -> Name;
        _ -> <<Name/binary, ": ", Message/binary>>
    end,
    E = bouy_heap:error_object(Proto, <<>>, <<Header/binary, "\n    at <anonymous>">>),
    case Message of
        undefined -> bouy_heap:delete(E, <<"message">>);
        _ -> bouy_heap:set(E, <<"message">>, Message)
    end,
    case ?IS_OBJECT(OptionsArg) andalso bouy_heap:has(OptionsArg, <<"cause">>) of
        true -> bouy_heap:define(E, <<"cause">>, #{value => bouy_ref:get(OptionsArg, <<"cause">>), writable => true, enumerable => false, configurable => true});
        false -> ok
    end,
    case Name of
        <<"AggregateError">> ->
            bouy_heap:define(E, <<"errors">>, #{value => bouy_heap:new_array(bouy_ref_iterator:to_list(arg(1, Args))), writable => true, enumerable => false, configurable => true});
        _ ->
            ok
    end,
    E.

error_to_string(E) ->
    Name = case bouy_ref:get(E, <<"name">>) of
        undefined -> <<"Error">>;
        N -> bouy_ref:to_string(N)
    end,
    Message = case bouy_ref:get(E, <<"message">>) of
        undefined -> <<>>;
        M -> bouy_ref:to_string(M)
    end,
    case {Name, Message} of
        {<<>>, _} -> Message;
        {_, <<>>} -> Name;
        _ -> <<Name/binary, ": ", Message/binary>>
    end.
