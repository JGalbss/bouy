%% The Error family: Error, the native errors, AggregateError, and
%% SuppressedError, with Error.prototype.toString, Error.isError, and V8's
%% Error.captureStackTrace and Error.stackTraceLimit.
%%
%% Error.prototype.stack is the accessor of the error stack accessor proposal:
%% its getter reads the stack of an error. Each error also keeps V8's own
%% `stack` property, because Node code and npm packages read it as an own
%% property and assign any value to it.
-module(buoy_ref_error).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, error_to_string/1, get_stack/2, set_stack/2]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(NATIVE, [<<"EvalError">>, <<"RangeError">>, <<"ReferenceError">>, <<"SyntaxError">>, <<"TypeError">>, <<"URIError">>]).
-define(NAMES, [<<"Error">>, <<"AggregateError">>, <<"SuppressedError">> | ?NATIVE]).
-define(STACK, {'#', ?MODULE, <<"stack">>}).
-define(FRAMES, <<"\n    at <anonymous>">>).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Subclasses = [<<"DataCloneError">>, <<"AggregateError">>, <<"SuppressedError">> | ?NATIVE],
    buoy_ref_realm:builtin(<<"Error stack get">>, <<>>, 0, fun ?MODULE:get_stack/2),
    buoy_ref_realm:builtin(<<"Error stack set">>, <<>>, 1, fun ?MODULE:set_stack/2),
    [{'Error.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Error.prototype">>, [{<<"toString">>, 0}]) ++ [{<<"name">>, <<"Error">>}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(<<"Error">>)}, {<<"stack">>, stack_accessor(), 4}], none)}]
    ++ [{prototype_id(N), record(object, {'$o', 'Error.prototype'}, [{<<"name">>, N}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(N)}], none)} || N <- Subclasses]
    ++ [{{builtin, <<"Error">>}, ctor_record(<<"Error">>, 1, {'$o', 'Error.prototype'}, ?METHODS(<<"Error">>, [{<<"captureStackTrace">>, 2}, {<<"isError">>, 1}]) ++ [{<<"stackTraceLimit">>, 10, 7}], fun(NT, Args) -> construct(<<"Error">>, NT, Args) end)}]
    ++ [{{builtin, N}, subclass_record(N)} || N <- [<<"AggregateError">>, <<"SuppressedError">> | ?NATIVE]].

%% A native error constructor: its prototype is %Error%.
subclass_record(Name) ->
    Length = case Name of
        <<"AggregateError">> -> 2;
        <<"SuppressedError">> -> 3;
        _ -> 1
    end,
    setelement(2, ctor_record(Name, Length, {'$o', prototype_id(Name)}, [], fun(NT, Args) -> construct(Name, NT, Args) end), constructor(<<"Error">>)).

prototype_id(Name) -> binary_to_atom(<<Name/binary, ".prototype">>).

stack_accessor() ->
    {'$accessor', buoy_ref_realm:builtin(<<"get Error.prototype.stack">>, <<"get stack">>, 0, fun(This, _) -> prototype_stack(This) end),
     buoy_ref_realm:builtin(<<"set Error.prototype.stack">>, <<"set stack">>, 1, fun(This, Args) -> set_prototype_stack(This, arg(1, Args)) end)}.

%% The getter: the stack of an object with [[ErrorData]], the lazy one of
%% lazy_stack/1 or the one that buoy_heap:error_object/3 keeps in the slots.
prototype_stack(E) ->
    ?IS_OBJECT(E) orelse buoy_ref:type_error(<<"get Error.prototype.stack requires that 'this' be an Object">>),
    case {buoy_heap:class_of(E), buoy_heap:private_find(E, ?STACK)} of
        {error, {ok, _}} -> get_stack(E, []);
        {error, error} -> buoy_heap:slots(E);
        _ -> undefined
    end.

%% The setter and SetterThatIgnoresPrototypeProperties(this, %Error.prototype%, "stack", V).
set_prototype_stack(E, V) ->
    ?IS_OBJECT(E) orelse buoy_ref:type_error(<<"set Error.prototype.stack requires that 'this' be an Object">>),
    ?IS_STRING(V) orelse buoy_ref:type_error(<<"Error.prototype.stack must be set to a string">>),
    E =:= buoy_ref_realm:current({'$o', 'Error.prototype'}) andalso
        buoy_ref:type_error(<<"Cannot assign to read only property 'stack' of object 'Error.prototype'">>),
    case buoy_heap:get_own(E, <<"stack">>) of
        none ->
            buoy_heap:define_own_property(E, <<"stack">>, #{value => V, writable => true, enumerable => true, configurable => true})
                orelse buoy_ref:type_error(<<"Cannot define property stack, object is not extensible">>);
        _ ->
            buoy_heap:set(E, <<"stack">>, V)
    end,
    undefined.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> buoy_ref_realm:constructor(?MODULE, Name).

%% An error constructor called without new constructs.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(Name, _This, Args) -> construct(Name, constructor(Name), Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Error.prototype">>, <<"toString">>, This, _) ->
    ?IS_OBJECT(This) orelse buoy_ref:type_error(<<"Error.prototype.toString requires that 'this' be an Object">>),
    error_to_string(This);
method(<<"Error">>, <<"isError">>, _This, Args) ->
    V = arg(1, Args),
    ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= error;
method(<<"Error">>, <<"captureStackTrace">>, _This, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse buoy_ref:type_error(<<"Invalid argument">>),
    lazy_stack(O),
    undefined.

%% V8's stack: an accessor that formats the header at its first read, so a
%% name or message that the code sets after the construction, as Node's
%% errors and DOMException do, reaches it. The value then stays.
lazy_stack(O) ->
    buoy_heap:private_put(O, ?STACK, pending),
    buoy_heap:define(O, <<"stack">>, #{get => buoy_ref_realm:builtin(<<"Error stack get">>, fun ?MODULE:get_stack/2),
                                       set => buoy_ref_realm:builtin(<<"Error stack set">>, fun ?MODULE:set_stack/2),
                                       enumerable => false, configurable => true}).

-spec get_stack(term(), list()) -> term().
get_stack(This, _Args) ->
    case holder(This) of
        {ok, Holder, pending} ->
            Header = try error_to_string(Holder) catch error:{'$throw', _} -> <<"Error">> end,
            Stack = buoy_ref_string:concat(Header, ?FRAMES),
            buoy_heap:private_put(Holder, ?STACK, {value, Stack}),
            Stack;
        {ok, _, {value, Stack}} ->
            Stack;
        error ->
            undefined
    end.

-spec set_stack(term(), list()) -> undefined.
set_stack(This, Args) ->
    ?IS_OBJECT(This) andalso buoy_heap:private_put(This, ?STACK, {value, arg(1, Args)}),
    undefined.

%% The object of the prototype chain of This that holds the stack.
holder(O) when ?IS_OBJECT(O) ->
    case buoy_heap:private_find(O, ?STACK) of
        {ok, State} -> {ok, O, State};
        error -> holder(buoy_heap:prototype_of(O))
    end;
holder(_) ->
    error.

%% The error constructors: OrdinaryCreateFromConstructor, the message, the
%% cause, and the errors of an AggregateError or the error and suppressed
%% values of a SuppressedError.
construct(Name, NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, prototype_id(Name)),
    {MessageArg, OptionsArg} = case Name of
        <<"AggregateError">> -> {arg(2, Args), arg(3, Args)};
        <<"SuppressedError">> -> {arg(3, Args), undefined};
        _ -> {arg(1, Args), arg(2, Args)}
    end,
    E = buoy_heap:error_object(Proto, <<>>, <<>>),
    case MessageArg of
        undefined -> buoy_heap:delete(E, <<"message">>);
        M -> buoy_heap:set(E, <<"message">>, buoy_ref:to_string(M))
    end,
    lazy_stack(E),
    case ?IS_OBJECT(OptionsArg) andalso buoy_heap:has(OptionsArg, <<"cause">>) of
        true -> hidden(E, <<"cause">>, buoy_ref:get(OptionsArg, <<"cause">>));
        false -> ok
    end,
    case Name of
        <<"AggregateError">> -> hidden(E, <<"errors">>, buoy_heap:new_array(buoy_ref_iterator:to_list(arg(1, Args))));
        <<"SuppressedError">> ->
            hidden(E, <<"error">>, arg(1, Args)),
            hidden(E, <<"suppressed">>, arg(2, Args));
        _ -> ok
    end,
    E.

hidden(O, K, V) -> buoy_heap:define(O, K, #{value => V, writable => true, enumerable => false, configurable => true}).

-spec error_to_string(term()) -> buoy_ref_string:js_string().
error_to_string(E) ->
    Name = case buoy_ref:get(E, <<"name">>) of
        undefined -> <<"Error">>;
        N -> buoy_ref:to_string(N)
    end,
    Message = case buoy_ref:get(E, <<"message">>) of
        undefined -> <<>>;
        M -> buoy_ref:to_string(M)
    end,
    case {Name, Message} of
        {<<>>, _} -> Message;
        {_, <<>>} -> Name;
        _ -> buoy_ref_string:concat([Name, <<": ">>, Message])
    end.
