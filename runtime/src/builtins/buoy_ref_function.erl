%% The Function family: the Function constructor, Function.prototype (call,
%% apply, bind, toString, and Symbol.hasInstance), bound functions, and
%% %ThrowTypeError%.
-module(buoy_ref_function).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, ordinary_has_instance/2, throw_type_error/0, prototype_call/2, kind_prototype_id/1]).

-import(buoy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(buoy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Thrower = throw_type_error(),
    Methods = ?METHODS(<<"Function.prototype">>, [{<<"call">>, 1}, {<<"apply">>, 2}, {<<"bind">>, 1}, {<<"toString">>, 0}]),
    HasInstance = buoy_ref_realm:builtin(<<"Function.prototype[Symbol.hasInstance]">>, <<"[Symbol.hasInstance]">>, 1,
                                         fun(This, Args) -> ?MODULE:method(<<"Function.prototype">>, <<"hasInstance">>, This, Args) end),
    %% length comes before name, as on every builtin function.
    Entries = [{<<"length">>, 0}, {<<"name">>, <<>>}] ++ Methods ++ [{<<"constructor">>, constructor()},
                          {?SYM(hasInstance), HasInstance},
                          {<<"caller">>, {'$accessor', Thrower, Thrower}}, {<<"arguments">>, {'$accessor', Thrower, Thrower}}],
    {Class, Proto, Props, Keys, Attrs, Slots} = record(function, ?OBJECT_PROTO, Entries, #{}),
    Fixed = #{<<"name">> => 4, <<"length">> => 4, ?SYM(hasInstance) => 0, <<"caller">> => 4, <<"arguments">> => 4},
    ThrowerRecord = {function, ?FUNCTION_PROTO, #{<<"length">> => 0, <<"name">> => <<>>}, [<<"name">>, <<"length">>],
                     #{<<"length">> => 0, <<"name">> => 0, '$noext' => true}, #{}},
    [{'Function.prototype', {Class, Proto, Props, Keys, maps:merge(Attrs, Fixed), Slots}},
     {{builtin, <<"ThrowTypeError">>}, ThrowerRecord},
     {{builtin, <<"Function">>}, ctor_record(<<"Function">>, 1, ?FUNCTION_PROTO, [], fun(NewTarget, Args) -> buoy_ref_eval:create_function(normal, Args, NewTarget) end)}].

%% The id of the prototype of the functions of a kind (buoy_ref_generator
%% holds the records).
-spec kind_prototype_id(generator | async | async_generator) -> atom().
kind_prototype_id(generator) -> 'GeneratorFunction.prototype';
kind_prototype_id(async) -> 'AsyncFunction.prototype';
kind_prototype_id(async_generator) -> 'AsyncGeneratorFunction.prototype'.

%% The [[Call]] of Function.prototype: it accepts any arguments and returns
%% undefined.
-spec prototype_call(term(), list()) -> undefined.
prototype_call(_This, _Args) -> undefined.

%% %ThrowTypeError%: one function in every realm.
-spec throw_type_error() -> term().
throw_type_error() -> buoy_ref_realm:builtin(<<"ThrowTypeError">>, fun buoy_ref:throw_type_error/2).

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Function">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Function">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Function">>, _This, Args) -> buoy_ref_eval:create_function(Args);
call_constructor(<<"GeneratorFunction">>, _This, Args) -> buoy_ref_eval:create_function(generator, Args, undefined);
call_constructor(<<"AsyncFunction">>, _This, Args) -> buoy_ref_eval:create_function(async, Args, undefined);
call_constructor(<<"AsyncGeneratorFunction">>, _This, Args) -> buoy_ref_eval:create_function(async_generator, Args, undefined).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Function.prototype">>, Name, This, Args) -> function_proto(Name, This, Args).

function_proto(<<"call">>, F, Args) ->
    buoy_ref:call(callable_this(F, <<"call">>), arg(1, Args), rest(2, Args));
function_proto(<<"apply">>, F, Args) ->
    Target = callable_this(F, <<"apply">>),
    List = case arg(2, Args) of
        A when A =:= undefined; A =:= null -> [];
        A -> buoy_ref_reflect:list_from_array_like(A)
    end,
    buoy_ref:call(Target, arg(1, Args), List);
function_proto(<<"bind">>, F, Args) ->
    bind(callable_this(F, <<"bind">>), arg(1, Args), rest(2, Args));
function_proto(<<"toString">>, F, _Args) ->
    buoy_heap:is_callable(F) orelse type_error(<<"Function.prototype.toString requires that 'this' be a Function">>),
    source_text(F);
function_proto(<<"hasInstance">>, F, Args) ->
    ordinary_has_instance(F, arg(1, Args)).

callable_this(F, Name) ->
    buoy_heap:is_callable(F) orelse type_error(<<"Function.prototype.", Name/binary, " called on a value that is not a function">>),
    F.

%% BoundFunctionCreate, with the length and name of Function.prototype.bind.
bind(Target, BoundThis, Bound) ->
    Length = case buoy_heap:has_own(Target, <<"length">>) of
        false -> 0;
        true -> bound_length(buoy_ref:get(Target, <<"length">>), length(Bound))
    end,
    Name = case buoy_ref:get(Target, <<"name">>) of
        N when ?IS_STRING(N) -> N;
        _ -> <<>>
    end,
    F = buoy_heap:function(fun(_This, More) -> buoy_ref:call(Target, BoundThis, Bound ++ More) end,
                           buoy_ref_string:concat(<<"bound ">>, Name), Length, #{kind => bound, target => Target}),
    case buoy_heap:is_constructor(Target) of
        true ->
            %% new.target stays the target when it is the bound function itself.
            Construct = fun(NewTarget, More) ->
                                NT = case NewTarget of
                                    F -> Target;
                                    _ -> NewTarget
                                end,
                                buoy_heap:construct(Target, Bound ++ More, NT)
                        end,
            buoy_heap:set_slots(F, #{kind => bound, target => Target, construct => Construct});
        false ->
            ok
    end,
    buoy_heap:set_prototype_of(F, buoy_heap:prototype_of(Target)).

bound_length('Infinity', _Count) -> 'Infinity';
bound_length(L, Count) when ?IS_NUMBER(L) ->
    case buoy_ref_number:to_integer_or_infinity(L) of
        '-Infinity' -> 0;
        'Infinity' -> 'Infinity';
        I -> max(I - Count, 0)
    end;
bound_length(_L, _Count) -> 0.

%% OrdinaryHasInstance.
-spec ordinary_has_instance(term(), term()) -> boolean().
ordinary_has_instance(C, V) ->
    case buoy_heap:is_callable(C) of
        false ->
            false;
        true ->
            case buoy_heap:slots(C) of
                #{kind := bound, target := Target} ->
                    buoy_ref:instance_of(V, Target);
                _ when ?IS_OBJECT(V) ->
                    Proto = buoy_ref:get(C, <<"prototype">>),
                    ?IS_OBJECT(Proto) orelse type_error(<<"Function has non-object prototype in instanceof check">>),
                    in_chain(buoy_heap:prototype_of(V), Proto);
                _ ->
                    false
            end
    end.

in_chain(null, _Proto) -> false;
in_chain(Proto, Proto) -> true;
in_chain(O, Proto) -> in_chain(buoy_heap:prototype_of(O), Proto).

%% Function.prototype.toString: the source text that the compiler kept, or
%% the NativeFunction form. The functions of buoy_temporal, the compiled
%% Temporal polyfill, are built-in functions, so they have the native form.
source_text(F) ->
    case {buoy_heap:slots(F), F} of
        {#{source := {buoy_temporal, _, _}}, _} -> native_text(F);
        {_, {'$f', {_Form, buoy_temporal, _, _}, _}} -> native_text(F);
        {#{source := {Module, Start, End}}, _} -> slice(Module, Start, End);
        {_, {'$f', {_Form, Module, Name, _}, _}} -> module_function_text(F, Module, Name);
        {_, {'$f', {_Form, Module, Name, _, sloppy}, _}} -> module_function_text(F, Module, Name);
        {#{kind := class}, _} -> buoy_ref_string:concat([<<"class ">>, name_of(F), <<" { }">>]);
        _ -> native_text(F)
    end.

module_function_text(F, Module, Name) ->
    case Module:'$span'(Name) of
        {Start, End} -> slice(Module, Start, End);
        none -> native_text(F)
    end.

%% The source text from byte Start to byte End of the module's '$source'/0.
slice(Module, Start, End) ->
    buoy_ref_string:from_utf8(binary:part(Module:'$source'(), Start, End - Start)).

%% NativeFunction syntax: a name that is not a property name, such as the
%% `$&` of a legacy RegExp accessor, is left out.
native_text(F) ->
    Name = name_of(F),
    Shown = case is_property_name(Name) of
        true -> Name;
        false -> <<>>
    end,
    buoy_ref_string:concat([<<"function ">>, Shown, <<"() { [native code] }">>]).

is_property_name(Name) when is_binary(Name) ->
    Bare = case Name of
        <<"get ", N/binary>> -> N;
        <<"set ", N/binary>> -> N;
        N -> N
    end,
    case Bare of
        <<"[", _/binary>> -> true;
        _ -> re:run(Bare, <<"^[A-Za-z_$][A-Za-z0-9_$]*$|^$">>, [{capture, none}]) =:= match
    end;
is_property_name(_) ->
    true.

name_of(F) ->
    case buoy_ref:get(F, <<"name">>) of
        N when ?IS_STRING(N) -> N;
        _ -> <<>>
    end.
