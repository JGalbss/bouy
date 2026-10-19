%% ShadowRealm (the ShadowRealm proposal, stage 2.7): a realm of the same
%% process whose code a program reaches only through primitive values and
%% wrapped functions.
%%
%% A ShadowRealm is the class shadow_realm with the slots #{realm => N}: N is a
%% realm of buoy_ref_realm:create/0, whose intrinsics are the twins of realm 0.
%% evaluate compiles its text as global code where it is called, so a syntax
%% error throws there, and runs it as an indirect eval in the realm N. A value
%% that crosses the boundary is a primitive or a callable, which becomes a
%% wrapped function of the other realm: a builtin of class function with the
%% slots #{kind => wrapped}, which wraps its arguments into the realm of its
%% target and its result back. Any error that crosses is a TypeError of the
%% realm that sees it.
-module(buoy_ref_shadow_realm).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref, [type_error/1]).

-define(PROTO, 'ShadowRealm.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"ShadowRealm.prototype">>, [{<<"evaluate">>, 1}, {<<"importValue">>, 2}]),
    [{?PROTO, record(object, ?OBJECT_PROTO, Methods ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"ShadowRealm">>, 4}], none)},
     {{builtin, <<"ShadowRealm">>}, ctor_record(<<"ShadowRealm">>, 0, {'$o', ?PROTO}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"ShadowRealm">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"ShadowRealm">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> type_error(<<"Constructor ShadowRealm requires 'new'">>).

construct(NewTarget, _Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    {'$o', {N, globalThis}} = buoy_ref_realm:create(),
    buoy_heap:new_exotic(shadow_realm, Proto, #{realm => N}).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"ShadowRealm.prototype">>, <<"evaluate">>, This, Args) ->
    N = realm_of(This, <<"evaluate">>),
    Source = arg(1, Args),
    ?IS_STRING(Source) orelse type_error(<<"ShadowRealm.prototype.evaluate takes a string">>),
    case buoy_ref_eval:shadow_evaluate(Source, N) of
        {ok, Value} -> wrap(Value);
        {error, _} -> type_error(<<"The code of the ShadowRealm threw">>)
    end;
method(<<"ShadowRealm.prototype">>, <<"importValue">>, This, Args) ->
    N = realm_of(This, <<"importValue">>),
    Specifier = buoy_ref:to_string(arg(1, Args)),
    ExportName = arg(2, Args),
    ?IS_STRING(ExportName) orelse type_error(<<"ShadowRealm.prototype.importValue takes the name of an export">>),
    import_value(Specifier, ExportName, N).

realm_of(This, Name) ->
    case ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= shadow_realm of
        true -> maps:get(realm, buoy_heap:slots(This));
        false -> type_error(<<"Method ShadowRealm.prototype.", Name/binary, " called on incompatible receiver">>)
    end.

%% ShadowRealmImportValue: the promise of the caller's realm settles with the
%% wrapped export, or a TypeError of the caller's realm.
import_value(Specifier, ExportName, N) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    Caller = buoy_heap:realm(),
    InCaller = fun(Fun) -> buoy_ref_realm:realm_fun(Caller, fun(_, _) -> Fun() end) end,
    Fail = InCaller(fun() -> Reject(error_object(<<"The module of the ShadowRealm failed to load">>)) end),
    Fulfilled = fun(Namespace) ->
                        Settle = InCaller(fun() ->
                                                  case buoy_heap:has(Namespace, ExportName) of
                                                      false -> Reject(error_object(<<"The module of the ShadowRealm does not export the name">>));
                                                      true ->
                                                          try wrap(buoy_heap:get(Namespace, ExportName)) of
                                                              Value -> Resolve(Value)
                                                          catch
                                                              error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
                                                          end
                                                  end
                                          end),
                        Settle(undefined, undefined)
                end,
    Rejected = fun(_Reason) -> Fail(undefined, undefined) end,
    Import = buoy_ref_realm:realm_fun(N, fun(_, _) ->
                                                 From = buoy_module:entry(),
                                                 Promise = buoy_module:dynamic_import(From, Specifier, undefined, evaluation),
                                                 buoy_jobs:perform_then(Promise, Fulfilled, Rejected, undefined)
                                         end),
    Import(undefined, undefined),
    P.

error_object(Message) -> buoy_heap:error_object('TypeError', Message, <<"TypeError: ", Message/binary>>).

%% GetWrappedValue into the current realm: a primitive as it is, a callable as
%% a new wrapped function, and a TypeError for any other object.
wrap(V) when ?IS_OBJECT(V) ->
    buoy_heap:is_callable(V) orelse type_error(<<"A value that crosses a ShadowRealm must be a primitive or a callable">>),
    wrapped_function(V);
wrap(V) -> V.

%% WrappedFunctionCreate: a function of the current realm with the length and
%% name of Target (CopyNameAndLength), whose failure is a TypeError.
wrapped_function(Target) ->
    {Name, Length} = try name_and_length(Target)
                     catch error:_ -> type_error(<<"The callable that crosses a ShadowRealm has no readable name or length">>)
                     end,
    buoy_heap:function(fun(This, Args) -> call(Target, This, Args) end, Name, Length, #{kind => wrapped}).

name_and_length(Target) ->
    Length = case buoy_heap:has_own(Target, <<"length">>) of
        false -> 0;
        true ->
            case buoy_heap:get(Target, <<"length">>) of
                'Infinity' -> 'Infinity';
                L when ?IS_NUMBER(L) ->
                    case buoy_ref_number:to_integer_or_infinity(L) of
                        '-Infinity' -> 0;
                        I -> max(0, I)
                    end;
                _ -> 0
            end
    end,
    Name = case buoy_heap:get(Target, <<"name">>) of
        S when ?IS_STRING(S) -> S;
        _ -> <<>>
    end,
    {Name, Length}.

%% The [[Call]] of a wrapped function, in the realm of the wrapper: the this
%% value and the arguments cross into the realm of the target, the result
%% crosses back, and any error is a TypeError here.
call(Target, This, Args) ->
    Values = [This | Args],
    lists:foreach(fun(V) ->
                          (?IS_OBJECT(V) andalso not buoy_heap:is_callable(V)) andalso
                              type_error(<<"A value that crosses a ShadowRealm must be a primitive or a callable">>)
                  end, Values),
    Realm = buoy_ref_realm:function_realm(Target),
    Run = buoy_ref_realm:realm_fun(Realm, fun(_, _) ->
                                                  try
                                                      [This1 | Args1] = [wrap(V) || V <- Values],
                                                      {ok, buoy_ref:call(Target, This1, Args1)}
                                                  catch
                                                      error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
                                                  end
                                          end),
    case Run(undefined, undefined) of
        {ok, Result} -> wrap(Result);
        {error, _} -> type_error(<<"The function of the other realm threw">>)
    end.
