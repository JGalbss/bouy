%% The Error family: Error, the native errors, AggregateError, and
%% SuppressedError, with Error.prototype.toString, Error.isError, and V8's
%% Error.captureStackTrace, Error.stackTraceLimit, and lazy `stack`.
%%
%% Error.prototype.stack is the accessor of the error stack accessor proposal:
%% its getter formats the stack of an error. Each error also keeps V8's own
%% `stack` property, because Node code and npm packages read it as an own
%% property and assign any value to it.
-module(buoy_ref_error).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, error_to_string/1, lazy_stack/0, get_stack/2, set_stack/2]).
-export([capture/2, call_sites/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(NATIVE, [<<"EvalError">>, <<"RangeError">>, <<"ReferenceError">>, <<"SyntaxError">>, <<"TypeError">>, <<"URIError">>]).
-define(NAMES, [<<"Error">>, <<"AggregateError">>, <<"SuppressedError">> | ?NATIVE]).

-define(FORMATTING, '$buoy_formatting_stack').
%% The stack that the own `stack` accessor of an error formatted or was set to.
-define(STACK, {'#', ?MODULE, <<"stack">>}).
%% The frames that the creation of an error or captureStackTrace captured
%% (buoy_stack), or none when Error.stackTraceLimit was no number.
-define(FRAMES, {'#', ?MODULE, <<"frames">>}).
%% What a CallSite answers (buoy_stack:call_site/1).
-define(SITE, {'#', ?MODULE, <<"site">>}).
-define(CALL_SITE, [{<<"getThis">>, undefined}, {<<"getTypeName">>, null}, {<<"getFunction">>, undefined},
                    {<<"getFunctionName">>, null}, {<<"getMethodName">>, null}, {<<"getFileName">>, undefined},
                    {<<"getLineNumber">>, null}, {<<"getColumnNumber">>, null}, {<<"getEvalOrigin">>, undefined},
                    {<<"isToplevel">>, true}, {<<"isEval">>, false}, {<<"isNative">>, false},
                    {<<"isConstructor">>, false}, {<<"isAsync">>, false}, {<<"isPromiseAll">>, false},
                    {<<"getPromiseIndex">>, null}, {<<"getScriptNameOrSourceURL">>, undefined},
                    {<<"getScriptHash">>, <<>>}, {<<"getEnclosingColumnNumber">>, null},
                    {<<"getEnclosingLineNumber">>, null}, {<<"getPosition">>, 0}, {<<"toString">>, <<"<anonymous>">>}]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    _ = buoy_ref_realm:builtin(<<"get stack">>, <<"get stack">>, 0, fun ?MODULE:get_stack/2),
    _ = buoy_ref_realm:builtin(<<"set stack">>, <<"set stack">>, 1, fun ?MODULE:set_stack/2),
    CallSite = ?METHODS(<<"CallSite.prototype">>, [{Name, 0} || {Name, _} <- ?CALL_SITE]),
    [{'CallSite.prototype', record(object, ?OBJECT_PROTO, CallSite, none)} | errors()].

errors() ->
    Subclasses = [<<"DataCloneError">>, <<"AggregateError">>, <<"SuppressedError">> | ?NATIVE],
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

%% The getter: the stack of an object with [[ErrorData]].
prototype_stack(E) ->
    ?IS_OBJECT(E) orelse buoy_ref:type_error(<<"get Error.prototype.stack requires that 'this' be an Object">>),
    case buoy_heap:class_of(E) of
        error -> format_stack(E);
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
method(<<"CallSite.prototype">>, Name, This, _) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?SITE) of
        {ok, Site} -> call_site_method(Name, Site);
        _ ->
            {Name, Value} = lists:keyfind(Name, 1, ?CALL_SITE),
            Value
    end;
method(<<"Error.prototype">>, <<"toString">>, This, _) ->
    ?IS_OBJECT(This) orelse buoy_ref:type_error(<<"Error.prototype.toString requires that 'this' be an Object">>),
    error_to_string(This);
method(<<"Error">>, <<"isError">>, _This, Args) ->
    V = arg(1, Args),
    ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= error;
method(<<"Error">>, <<"captureStackTrace">>, _This, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse buoy_ref:type_error(<<"Invalid argument">>),
    capture(O, buoy_stack:function_start(arg(2, Args))),
    {'$accessor', Get, Set} = lazy_stack(),
    buoy_heap:define(O, <<"stack">>, #{get => Get, set => Set, enumerable => false, configurable => true}),
    undefined.

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
    E = buoy_heap:error_object(Proto, <<>>),
    case MessageArg of
        undefined -> buoy_heap:delete(E, <<"message">>);
        M -> buoy_heap:set(E, <<"message">>, buoy_ref:to_string(M))
    end,
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

%%% The stack

%% The `stack` of an error, as V8 installs it: an own accessor that formats
%% the stack on its first read, so it shows the name, message, and code that
%% the error has by then, as Node's errors set them after their constructor.
%% It stays an accessor, and later reads give the same text.
-spec lazy_stack() -> {'$accessor', term(), term()}.
lazy_stack() ->
    {'$accessor', buoy_ref_realm:builtin(<<"get stack">>, fun ?MODULE:get_stack/2),
     buoy_ref_realm:builtin(<<"set stack">>, fun ?MODULE:set_stack/2)}.

-spec get_stack(term(), list()) -> term().
get_stack(This, _Args) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?STACK) of
        {ok, Kept} ->
            Kept;
        _ ->
            Stack = format_stack(This),
            keep_stack(This, Stack),
            Stack
    end.

-spec set_stack(term(), list()) -> undefined.
set_stack(This, Args) ->
    keep_stack(This, arg(1, Args)),
    undefined.

keep_stack(O, Stack) when ?IS_OBJECT(O) ->
    buoy_heap:private_put(O, ?STACK, Stack);
keep_stack(_, _) ->
    ok.

%% Captures the frames of the stack into O, at most Error.stackTraceLimit of
%% the current realm and below the function at Skip (buoy_stack:capture/2).
-spec capture(term(), {module(), non_neg_integer()} | none) -> ok.
capture(O, Skip) ->
    Error = buoy_ref_realm:current(constructor(<<"Error">>)),
    Frames = case buoy_heap:get_own(Error, <<"stackTraceLimit">>) of
        {data, Limit, _} when is_number(Limit) -> buoy_stack:capture(frame_count(Limit), Skip);
        {data, Limit, _} when Limit =:= 'Infinity' -> buoy_stack:capture(1024, Skip);
        {data, Limit, _} when Limit =:= '-Infinity'; Limit =:= 'NaN' -> [];
        _ -> none
    end,
    buoy_heap:private_put(O, ?FRAMES, Frames).

frame_count(Limit) when Limit =< 0 -> 0;
frame_count(Limit) -> min(trunc(Limit), 1024).

%% The CallSite objects of the frames that O captured.
-spec call_sites(term()) -> [term()].
call_sites(O) ->
    case ?IS_OBJECT(O) andalso buoy_heap:private_find(O, ?FRAMES) of
        {ok, Frames} when is_list(Frames) -> [call_site(Frame) || Frame <- Frames];
        _ -> []
    end.

call_site(Frame) ->
    Site = buoy_heap:new_object(buoy_heap:intrinsic('CallSite.prototype')),
    buoy_heap:private_put(Site, ?SITE, buoy_stack:call_site(Frame)),
    Site.

%% CallSite.prototype.X of a frame, as V8's CallSiteInfo answers. A method is
%% a function of a class or of an object literal, which V8 calls with that
%% receiver; the receiver itself is not kept.
call_site_method(<<"getThis">>, _) -> undefined;
call_site_method(<<"getFunction">>, _) -> undefined;
call_site_method(<<"getTypeName">>, #{holder := Holder}) when is_binary(Holder) -> Holder;
call_site_method(<<"getTypeName">>, _) -> null;
call_site_method(<<"getFunctionName">>, #{kind := wrapper}) -> null;
call_site_method(<<"getFunctionName">>, #{name := <<>>}) -> null;
call_site_method(<<"getFunctionName">>, #{name := Name}) -> Name;
call_site_method(<<"getMethodName">>, #{kind := method, name := Name}) when Name =/= <<>> -> Name;
call_site_method(<<"getMethodName">>, _) -> null;
call_site_method(<<"getFileName">>, #{file := File}) -> File;
call_site_method(<<"getScriptNameOrSourceURL">>, #{file := File}) -> File;
call_site_method(<<"getLineNumber">>, #{line := Line}) -> Line;
call_site_method(<<"getColumnNumber">>, #{column := Column}) -> Column;
call_site_method(<<"getEvalOrigin">>, _) -> undefined;
call_site_method(<<"isToplevel">>, Site) -> is_toplevel(Site);
call_site_method(<<"isConstructor">>, #{kind := Kind}) -> Kind =:= constructor;
call_site_method(<<"toString">>, Site) -> site_text(Site);
call_site_method(Name, _) ->
    {Name, Value} = lists:keyfind(Name, 1, ?CALL_SITE),
    Value.

%% A frame whose receiver is the global object or undefined: a function that
%% no object holds.
is_toplevel(#{kind := Kind, holder := Holder}) ->
    Holder =:= undefined andalso Kind =/= constructor.

%% The text of a frame in a stack trace, as V8's CallSiteInfo::Serialize
%% writes it: `new F (place)`, `Type.method [as key] (place)`, `f (place)`,
%% or the place alone for an anonymous function.
site_text(#{kind := Kind, name := Name, holder := Holder} = Site) ->
    Place = place_text(Site),
    Described = case {Kind, Name, Holder} of
        {constructor, _, _} -> [<<"new ">>, anonymous(Name)];
        {wrapper, _, undefined} -> none;
        {wrapper, _, _} -> [Holder, <<".<anonymous>">>];
        {_, <<>>, undefined} -> none;
        {_, <<>>, _} -> [Holder, <<".<anonymous>">>];
        {_, _, undefined} -> [Name];
        {_, _, _} -> method_text(Holder, Name)
    end,
    case Described of
        none -> Place;
        _ -> buoy_ref_string:from_utf8(iolist_to_binary([Described, <<" (">>, Place, <<")">>]))
    end.

anonymous(<<>>) -> <<"<anonymous>">>;
anonymous(Name) -> Name.

method_text(Holder, Name) ->
    case binary:match(Name, <<Holder/binary, ".">>) of
        {0, _} -> [Name];
        _ -> [Holder, <<".">>, Name]
    end.

place_text(#{file := File, line := Line, column := Column}) ->
    Script = case File of
        undefined -> <<"<anonymous>">>;
        _ -> buoy_ref_string:to_utf8(File)
    end,
    buoy_ref_string:from_utf8(iolist_to_binary([Script, $:, integer_to_binary(Line), $:, integer_to_binary(Column)])).

%% V8 hands the error and its structured trace to the PrepareStackTrace
%% callback of the embedder, which Node sets (internalBinding('errors')), else
%% to Error.prepareStackTrace of the realm, else it writes the header and the
%% frames. A stack that formats while another one formats takes the default,
%% as in V8. An error that was made while Error.stackTraceLimit was no number
%% has no stack.
format_stack(E) ->
    case buoy_heap:private_find(E, ?FRAMES) of
        {ok, none} -> undefined;
        _ ->
            Error = buoy_ref_realm:current(constructor(<<"Error">>)),
            Frames = call_sites(E),
            case erlang:get(?FORMATTING) of
                undefined -> prepare_stack(Error, E, Frames);
                _ -> default_stack(E, Frames)
            end
    end.

prepare_stack(Error, E, Frames) ->
    case buoy_binding_errors:hook(<<"setPrepareStackTraceCallback">>) of
        undefined ->
            User = buoy_heap:get(Error, <<"prepareStackTrace">>),
            case buoy_heap:is_callable(User) of
                true -> formatting(fun() -> buoy_heap:call(User, Error, [E, buoy_heap:new_array(Frames)]) end);
                false -> default_stack(E, Frames)
            end;
        Callback ->
            formatting(fun() -> buoy_heap:call(Callback, undefined, [buoy_ref_realm:global_object(), E, buoy_heap:new_array(Frames)]) end)
    end.

formatting(Format) ->
    erlang:put(?FORMATTING, true),
    try Format()
    after
        erlang:erase(?FORMATTING)
    end.

default_stack(E, Frames) ->
    Header = try error_to_string(E) catch error:{'$throw', _} -> <<"<error>">> end,
    buoy_ref_string:concat([Header | [buoy_ref_string:concat(<<"\n    at ">>, site_text(site_of(F))) || F <- Frames]]).

site_of(Site) ->
    {ok, Map} = buoy_heap:private_find(Site, ?SITE),
    Map.
