%% The operations that compiled reference-semantics code calls.
%%
%% Values are undefined, null, booleans, numbers (buoy_ref_number), strings
%% (buoy_ref_string), the heap values of buoy_heap (objects, functions, and
%% symbols), and {'$actor', Pid} for an actor ref. Property reads on a
%% primitive go to the intrinsic prototype of its type, as in JavaScript.
-module(buoy_ref).

-export([init_realm/0, global/1, caught/2, report_uncaught/1, exit_program/1, stderr/0, type_error/1]).
-export_type([exit_status/0]).

-type exit_status() :: 0..255.
-export([get/2, get_from/3, get_computed/2, set/3, set_computed/3, delete/2, delete_computed/2, in/2, to_property_key/1, member_key/2]).
-export([sloppy_set/3, sloppy_set_computed/3, sloppy_delete/2, sloppy_delete_computed/2, sloppy_this/1]).
-export([mapped_arguments/3, function_name/2, literal_proto/2, tdz_error/1]).
-export([with_object/1, with_has/2, with_get/3, with_set/4, const_error/0]).
-export([call/3, call_method/3, call_method_computed/3, call_method_value/4, construct/2, new_this/1, super_construct/3, super_get/3, super_call/4]).
-export([arguments_object/1, throw_type_error/2, named_fn/3, named_fn/4, class_create/3, set_construct/2, define_method/3, define_getter/3, define_setter/3, define_field/3]).
-export([literal_getter/3, literal_setter/3, class_call/2]).
-export([array/1, array_holes/1, array_spread/1, chunk/1, object_spread/2, object_rest/2, template/1, template_object/3]).
-export([add/2, sub/2, mul/2, divide/2, remainder/2, power/2, negate/1, plus/1]).
-export([bit_and/2, bit_or/2, bit_xor/2, bit_not/1, shift_left/2, shift_right/2, shift_right_unsigned/2]).
-export([strict_eq/2, loose_eq/2, lt/2, le/2, gt/2, ge/2, typeof/1, instance_of/2, truthy/1]).
-export([to_string/1, to_number/1, to_numeric/1, to_object/1, to_primitive/2, increment/1, decrement/1]).
-export([describe/1, typeof_global/1, spawn_args/1, stop_actor/1, heap_stats/0, vm_memory/0]).

-include("buoy_ref.hrl").

%%% Realm

%% Installs the static intrinsics once per VM. Each realm starts empty: its
%% intrinsics read through to the static records until the realm writes one.
-spec init_realm() -> ok.
init_realm() -> buoy_ref_realm:install().

-spec global(binary()) -> term().
global(Name) -> buoy_ref_realm:global(Name).

%%% Errors

-spec type_error(buoy_ref_string:js_string()) -> no_return().
type_error(Message) -> buoy_heap:throw_error('TypeError', Message).

%% The JavaScript value of an Erlang exception: a thrown value, or a
%% TypeError for a runtime error of the generated code, which names the
%% Erlang reason so a gap in the spike shows where it is.
-spec caught(term(), list()) -> term().
caught({'$throw', Value}, _Stack) ->
    Value;
caught(Reason, Stack) ->
    Where = case Stack of
        [{M, F, A, Info} | _] -> io_lib:format(" at ~s:~s/~w line ~w", [M, F, arity(A), proplists:get_value(line, Info, 0)]);
        _ -> ""
    end,
    Message = buoy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("~0tP~s", [Reason, 8, Where]))),
    buoy_heap:error_object('TypeError', Message, text([<<"TypeError: ">>, Message])).

arity(A) when is_list(A) -> length(A);
arity(A) -> A.

%% An uncaught error ends the program with status 1, as in Node.
-spec report_uncaught(term()) -> no_return().
report_uncaught(Value) ->
    Text = try uncaught_text(Value)
           catch _:_ -> io_lib:format("~0tp", [Value])
           end,
    io:put_chars(stderr(), ["Uncaught ", Text, "\n"]),
    exit_program(1).

%% Ends the program with Status. A realm that a test runner starts sets
%% '$buoy_exit' in its process dictionary: the realm then exits with
%% {'$buoy_exit', Status}, and the VM goes on.
-spec exit_program(exit_status()) -> no_return().
exit_program(Status) ->
    case erlang:get('$buoy_exit') of
        undefined -> buoy_main:finish(Status, #{});
        _ -> exit({'$buoy_exit', Status})
    end.

%% The device of stderr: '$buoy_stderr' in the process dictionary of a realm
%% that a test runner starts, else standard_error.
-spec stderr() -> io:device().
stderr() ->
    case erlang:get('$buoy_stderr') of
        undefined -> standard_error;
        Device -> Device
    end.

uncaught_text({'$o', _} = O) ->
    case buoy_heap:class_of(O) of
        error -> buoy_ref_string:to_utf8(to_string(O));
        _ -> buoy_ref_console:inspect(O)
    end;
uncaught_text(V) ->
    buoy_ref_console:inspect(V).

%%% Properties

-spec get(term(), buoy_heap:key()) -> term().
get({'$o', _} = O, K) -> buoy_heap:get(O, K);
get({'$f', _, _} = F, K) -> buoy_heap:get(F, K);
get(S, K) when ?IS_STRING(S) -> buoy_ref_string:get(S, K);
get(undefined, K) -> read_error(<<"undefined">>, K);
get(null, K) -> read_error(<<"null">>, K);
get(B, K) when is_boolean(B) -> lookup(buoy_heap:intrinsic('Boolean.prototype'), K, B);
get(N, K) when ?IS_NUMBER(N) -> lookup(buoy_heap:intrinsic('Number.prototype'), K, N);
get({'$bigint', _} = B, K) -> lookup(buoy_heap:intrinsic('BigInt.prototype'), K, B);
get({'$sym', _, Description}, <<"description">>) -> Description;
get({'$sym', _, _} = S, K) -> lookup(buoy_heap:intrinsic('Symbol.prototype'), K, S);
get({'$actor', Pid}, K) when ?IS_STRING(K) -> {'$f', {actor, Pid, K}, fun(_This, Args) -> buoy_jobs:actor_call(Pid, K, Args) end};
get({'$actor', _}, _K) -> undefined.

-spec read_error(binary(), buoy_heap:key()) -> no_return().
read_error(What, K) ->
    type_error(text([<<"Cannot read properties of ">>, What, <<" (reading '">>, key_text(K), <<"')">>])).

%% A message from strings of the engine.
text(Parts) -> buoy_ref_string:concat(Parts).

-spec get_computed(term(), term()) -> term().
get_computed(O, K) -> get(O, member_key(O, K)).

-spec set(term(), buoy_heap:key(), term()) -> term().
set({'$o', _} = O, K, V) -> buoy_heap:set(O, K, V);
set({'$f', _, _} = F, K, V) -> buoy_heap:set(F, K, V);
set(undefined, K, _V) -> cannot_set(<<"undefined">>, K);
set(null, K, _V) -> cannot_set(<<"null">>, K);
set(P, K, V) ->
    primitive_set(P, K, V) orelse type_error(text([<<"Cannot create property '">>, key_text(K), <<"' on ">>, typeof(P), <<" '">>, to_string(P), <<"'">>])),
    V.

-spec set_computed(term(), term(), term()) -> term().
set_computed(O, K, _V) when O =:= undefined; O =:= null -> cannot_set(atom_to_binary(O), key_preview(K));
set_computed(O, K, V) -> set(O, to_property_key(K), V).

-spec cannot_set(binary(), buoy_heap:key()) -> no_return().
cannot_set(What, K) -> type_error(text([<<"Cannot set properties of ">>, What, <<" (setting '">>, key_text(K), <<"')">>])).

%% `o[k] = v` in sloppy code: a write that fails does nothing, and a write to a
%% primitive runs only a setter of its prototype.
-spec sloppy_set(term(), buoy_heap:key(), term()) -> term().
sloppy_set({'$o', _} = O, K, V) -> buoy_heap:sloppy_set(O, K, V);
sloppy_set({'$f', _, _} = F, K, V) -> buoy_heap:sloppy_set(F, K, V);
sloppy_set(undefined, K, _V) -> cannot_set(<<"undefined">>, K);
sloppy_set(null, K, _V) -> cannot_set(<<"null">>, K);
sloppy_set(P, K, V) ->
    _ = primitive_set(P, K, V),
    V.

%% PutValue on a primitive base: [[Set]] of ToObject(base) with the
%% primitive as the receiver, so only a setter up the chain takes the
%% write. The own indexes and length of a string are read-only.
primitive_set({'$actor', _}, _K, _V) -> false;
primitive_set(S, <<"length">>, _V) when ?IS_STRING(S) -> false;
primitive_set(S, I, V) when ?IS_STRING(S), is_integer(I) ->
    I >= buoy_ref_string:length_of(S) andalso buoy_heap:set(primitive_proto(S), I, V, S);
primitive_set(P, K, V) -> buoy_heap:set(primitive_proto(P), K, V, P).

primitive_proto(S) when ?IS_STRING(S) -> buoy_heap:intrinsic('String.prototype');
primitive_proto(B) when is_boolean(B) -> buoy_heap:intrinsic('Boolean.prototype');
primitive_proto({'$sym', _, _}) -> buoy_heap:intrinsic('Symbol.prototype');
primitive_proto({'$bigint', _}) -> buoy_heap:intrinsic('BigInt.prototype');
primitive_proto(_) -> buoy_heap:intrinsic('Number.prototype').

-spec sloppy_set_computed(term(), term(), term()) -> term().
sloppy_set_computed(O, K, _V) when O =:= undefined; O =:= null -> cannot_set(atom_to_binary(O), key_preview(K));
sloppy_set_computed(O, K, V) -> sloppy_set(O, to_property_key(K), V).

%% `delete o[k]` in sloppy code: false for a property that cannot go.
-spec sloppy_delete(term(), buoy_heap:key()) -> boolean().
sloppy_delete(O, K) when ?IS_OBJECT(O) -> buoy_heap:delete_property(O, K);
sloppy_delete(O, K) -> delete(O, K).

-spec sloppy_delete_computed(term(), term()) -> boolean().
sloppy_delete_computed(O, K) when O =:= undefined; O =:= null -> delete(O, key_preview(K));
sloppy_delete_computed(O, K) -> sloppy_delete(O, to_property_key(K)).

%% The this of a sloppy function: the global object for undefined and null.
-spec sloppy_this(term()) -> term().
sloppy_this(This) when This =:= undefined; This =:= null -> buoy_ref_realm:global_object();
sloppy_this(This) -> to_object(This).

-spec delete(term(), buoy_heap:key()) -> boolean().
delete(O, K) when ?IS_OBJECT(O) -> buoy_heap:delete(O, K);
delete(undefined, K) -> type_error(text([<<"Cannot convert undefined or null to object (deleting '">>, key_text(K), <<"')">>]));
delete(null, K) -> delete(undefined, K);
delete(_P, _K) -> true.

-spec delete_computed(term(), term()) -> boolean().
delete_computed(O, K) when O =:= undefined; O =:= null -> delete(O, key_preview(K));
delete_computed(O, K) -> delete(O, to_property_key(K)).

%% `k in o`.
-spec in(term(), term()) -> boolean().
in(K, O) when ?IS_OBJECT(O) -> buoy_heap:has(O, to_property_key(K));
in(K, O) -> type_error(text([<<"Cannot use 'in' operator to search for '">>, to_string(K), <<"' in ">>, describe(O)])).

%% The key of o[k]: the base must not be undefined or null before the key
%% converts (GetValue and PutValue run ToObject before ToPropertyKey).
-spec member_key(term(), term()) -> buoy_heap:key().
member_key(undefined, K) -> read_error(<<"undefined">>, key_preview(K));
member_key(null, K) -> read_error(<<"null">>, key_preview(K));
member_key(_O, K) -> to_property_key(K).

key_preview(K) when ?IS_OBJECT(K) -> <<"[object]">>;
key_preview(K) -> to_property_key(K).

-spec to_property_key(term()) -> buoy_heap:key().
to_property_key(K) when ?IS_OBJECT(K) -> to_property_key(to_primitive(K, string));
to_property_key({'$bigint', _} = K) -> buoy_heap:to_key(to_string(K));
to_property_key(K) -> buoy_heap:to_key(K).

key_text(K) when ?IS_STRING(K) -> K;
key_text(K) when is_integer(K) -> integer_to_binary(K);
key_text({'$sym', _, undefined}) -> <<"Symbol()">>;
key_text({'$sym', _, D}) -> text([<<"Symbol(">>, to_string(D), <<")">>]);
key_text({'#', _, Name}) -> text([<<"#">>, Name]);
key_text(K) -> to_string(K).

%%% Calls

-spec call(term(), term(), list()) -> term().
call({'$f', _, Fun}, This, Args) -> Fun(This, Args);
call(V, _This, _Args) -> type_error(text([describe(V), <<" is not a function">>])).

%% r.k(args): the method of the receiver, called with the receiver as this.
-spec call_method(term(), buoy_heap:key(), list()) -> term().
call_method({'$o', _} = O, K, Args) -> invoke(buoy_heap:method(O, K), O, K, Args);
call_method({'$actor', Pid}, K, Args) -> buoy_jobs:actor_call(Pid, K, Args);
call_method(R, K, Args) -> invoke(get(R, K), R, K, Args).

%% r.k(args) where the code read the method before the arguments ran.
-spec call_method_value(term(), term(), buoy_heap:key(), list()) -> term().
call_method_value(F, This, K, Args) -> invoke(F, This, K, Args).

invoke({'$f', _, Fun}, This, _K, Args) -> Fun(This, Args);
invoke(_V, This, K, _Args) -> type_error(text([receiver_text(This), <<".">>, key_text(K), <<" is not a function">>])).

receiver_text(V) when ?IS_OBJECT(V) -> <<"object">>;
receiver_text(V) -> describe(V).

-spec call_method_computed(term(), term(), list()) -> term().
call_method_computed(R, K, Args) -> call_method(R, to_property_key(K), Args).

-spec construct(term(), list()) -> term().
construct(F, Args) -> buoy_heap:construct(F, Args, F).

%% The this of a base class constructor: an object whose prototype is the
%% prototype of new.target.
-spec new_this(term()) -> term().
new_this(NewTarget) -> buoy_heap:new_object(buoy_ref_realm:proto_for(NewTarget, 'Object.prototype')).

-spec super_construct(term(), list(), term()) -> term().
super_construct(Parent, Args, NewTarget) -> buoy_heap:construct(Parent, Args, NewTarget).

%% super.k inside a method whose home object is Home, with this as receiver.
-spec super_get(term(), buoy_heap:key(), term()) -> term().
super_get(Home, K, This) -> lookup(buoy_heap:prototype_of(Home), K, This).

%% [[Get]] of K on the object O with Receiver as this for a getter, as a
%% property read on a primitive does on its prototype.
-spec get_from(term(), buoy_heap:key(), term()) -> term().
get_from(O, K, Receiver) -> lookup(O, K, Receiver).

lookup(null, _K, _Receiver) ->
    undefined;
lookup(O, K, Receiver) ->
    case buoy_heap:get_own(O, K) of
        {data, V, _} -> V;
        {accessor, undefined, _, _} -> undefined;
        {accessor, G, _, _} -> call(G, Receiver, []);
        none -> lookup(buoy_heap:prototype_of(O), K, Receiver)
    end.

-spec super_call(term(), buoy_heap:key(), term(), list()) -> term().
super_call(Home, K, This, Args) -> invoke(super_get(Home, K, This), This, K, Args).

%%% Functions and classes

%% The unmapped arguments object of a function call, as in strict code: the
%% arguments by index, length, the array iterator, and a callee that throws.
-spec arguments_object(list()) -> term().
arguments_object(Args) ->
    O = buoy_heap:new_exotic(arguments, ?OBJECT_PROTO, none),
    [buoy_heap:define(O, I, #{value => V, writable => true, enumerable => true, configurable => true}) || {I, V} <- lists:enumerate(0, Args)],
    buoy_heap:define(O, <<"length">>, #{value => length(Args), writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(O, ?SYM(iterator), #{value => buoy_heap:get(buoy_heap:intrinsic('Array.prototype'), ?SYM(iterator)),
                                          writable => true, enumerable => false, configurable => true}),
    Thrower = buoy_ref_realm:current(buoy_ref_function:throw_type_error()),
    buoy_heap:define(O, <<"callee">>, #{get => Thrower, set => Thrower, enumerable => false, configurable => false}),
    O.

%% The mapped arguments object of a sloppy function with simple parameters
%% (ECMA-262 §10.4.4.7): an index below the argument count shares the cell
%% of its parameter, and callee is the function.
-spec mapped_arguments(list(), list(), term()) -> term().
mapped_arguments(Args, Cells, Callee) ->
    O = buoy_heap:new_exotic(arguments, ?OBJECT_PROTO, none),
    [buoy_heap:define(O, I, #{value => V, writable => true, enumerable => true, configurable => true}) || {I, V} <- lists:enumerate(0, Args)],
    buoy_heap:define(O, <<"length">>, #{value => length(Args), writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(O, ?SYM(iterator), #{value => buoy_heap:get(buoy_heap:intrinsic('Array.prototype'), ?SYM(iterator)),
                                          writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(O, <<"callee">>, #{value => Callee, writable => true, enumerable => false, configurable => true}),
    Count = min(length(Args), length(Cells)),
    Map = maps:from_list([{I, Cell} || {I, Cell} <- lists:enumerate(0, lists:sublist(Cells, Count)), Cell =/= undefined]),
    buoy_heap:set_slots(O, Map),
    O.

%% %ThrowTypeError%: the accessor of callee on an arguments object.
-spec throw_type_error(term(), list()) -> no_return().
throw_type_error(_This, _Args) ->
    type_error(<<"'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them">>).

%% A function declaration or expression: it has a name and a prototype
%% object, so new works on it.
-spec named_fn(fun((term(), list()) -> term()), binary(), non_neg_integer()) -> term().
named_fn(Fun, Name, Length) -> named_fn(Fun, Name, Length, normal).

%% The name of a function from a property key, as SetFunctionName gives it:
%% a symbol's description in brackets, and a prefix such as "get".
-spec function_name(buoy_heap:key(), buoy_ref_string:js_string()) -> buoy_ref_string:js_string().
function_name(K, Prefix) ->
    Name = case K of
        {'$sym', _, undefined} -> <<>>;
        {'$sym', _, D} -> text([<<"[">>, D, <<"]">>]);
        I when is_integer(I) -> integer_to_binary(I);
        S -> S
    end,
    case Prefix of
        <<>> -> Name;
        _ -> text([Prefix, <<" ">>, Name])
    end.

%% `__proto__: v` in an object literal: an object or null becomes the prototype.
-spec literal_proto(term(), term()) -> ok.
literal_proto(O, Proto) when ?IS_OBJECT(Proto); Proto =:= null ->
    _ = buoy_heap:set_prototype_of(O, Proto),
    ok;
literal_proto(_O, _Proto) ->
    ok.

%% An assignment to a const binding.
-spec const_error() -> no_return().
const_error() -> type_error(<<"Assignment to constant variable.">>).

%% The object of `with (v)`: ToObject, a TypeError for undefined and null.
-spec with_object(term()) -> term().
with_object(V) -> to_object(V).

%% Whether the object environment of a `with` statement binds Name
%% (HasBinding of ECMA-262 §9.1.1.2.1): the object has the property, and its
%% Symbol.unscopables does not block it.
-spec with_has(term(), buoy_ref_string:js_string()) -> boolean().
with_has(O, Name) when ?IS_OBJECT(O) ->
    K = buoy_heap:to_key(Name),
    buoy_heap:has(O, K) andalso not unscopable(get(O, ?SYM(unscopables)), K);
with_has(P, Name) ->
    buoy_heap:has(primitive_proto(P), buoy_heap:to_key(Name)).

unscopable(U, K) when ?IS_OBJECT(U) -> truthy(get(U, K));
unscopable(_U, _K) -> false.

%% GetBindingValue of an object environment (ECMA-262 §9.1.1.2.6): the
%% property may be gone since the name resolved, which strict code reports.
-spec with_get(term(), buoy_ref_string:js_string(), boolean()) -> term().
with_get(O, Name, Strict) when ?IS_OBJECT(O) ->
    K = buoy_heap:to_key(Name),
    case buoy_heap:has(O, K) of
        true -> get(O, K);
        false when Strict -> buoy_ref_realm:not_defined(Name);
        false -> undefined
    end;
with_get(P, Name, _Strict) ->
    get(P, buoy_heap:to_key(Name)).

%% SetMutableBinding of an object environment (§9.1.1.2.5): strict code
%% reports a property that went away, and its failed Set throws.
-spec with_set(term(), buoy_ref_string:js_string(), term(), boolean()) -> term().
with_set(O, Name, V, Strict) when ?IS_OBJECT(O) ->
    K = buoy_heap:to_key(Name),
    case {buoy_heap:has(O, K), Strict} of
        {false, true} -> buoy_ref_realm:not_defined(Name);
        {true, true} -> set(O, K, V);
        {_, false} -> sloppy_set(O, K, V)
    end;
with_set(P, Name, V, _Strict) ->
    sloppy_set(P, buoy_heap:to_key(Name), V).

-spec tdz_error(buoy_ref_string:js_string()) -> no_return().
tdz_error(Name) ->
    buoy_heap:throw_error('ReferenceError', text([<<"Cannot access '">>, Name, <<"' before initialization">>])).

%% A function of a kind: normal, which new can construct, generator or
%% async_generator, whose prototype object is the prototype of the
%% generators it makes, or async, which has no prototype.
-type fn_kind() :: normal | sloppy | generator | async | async_generator.
-spec named_fn(fun((term(), list()) -> term()), buoy_ref_string:js_string(), non_neg_integer(), fn_kind() | {fn_kind(), tuple()}) -> term().
named_fn(Fun, Name, Length, Kind) ->
    finish_fn(buoy_heap:function(Fun, Name, Length, slots(Kind)), kind(Kind)).

%% The kind of named_fn may carry the place of the source text: {Kind, Source}.
slots({Kind, Source}) -> #{kind => slot_kind(Kind), source => Source};
slots(Kind) -> #{kind => slot_kind(Kind)}.

kind({Kind, _Source}) -> Kind;
kind(Kind) -> Kind.

%% A sloppy function is a normal one with the caller and arguments
%% properties that V8 gives it, both null.
slot_kind(sloppy) -> normal;
slot_kind(Kind) -> Kind.

finish_fn(F, sloppy) ->
    buoy_heap:define(F, <<"arguments">>, #{value => null, writable => false, enumerable => false, configurable => false}),
    buoy_heap:define(F, <<"caller">>, #{value => null, writable => false, enumerable => false, configurable => false}),
    finish_fn(F, normal);
finish_fn(F, normal) ->
    Proto = buoy_heap:new_object(?OBJECT_PROTO),
    buoy_heap:define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(F, <<"prototype">>, #{value => Proto, writable => true, enumerable => false, configurable => false}),
    F;
finish_fn(F, async) ->
    buoy_heap:set_prototype_of(F, buoy_heap:intrinsic(buoy_ref_function:kind_prototype_id(async)));
finish_fn(F, Kind) ->
    Parent = case Kind of
        generator -> buoy_heap:intrinsic('Generator.prototype');
        async_generator -> buoy_heap:intrinsic('AsyncGenerator.prototype')
    end,
    buoy_heap:define(F, <<"prototype">>, #{value => buoy_heap:new_object(Parent), writable => true, enumerable => false, configurable => false}),
    buoy_heap:set_prototype_of(F, buoy_heap:intrinsic(buoy_ref_function:kind_prototype_id(Kind))).

%% ClassDefinitionEvaluation up to the methods: the constructor function
%% and its prototype object. Parent is none without extends.
-spec class_create(binary(), term(), non_neg_integer()) -> {term(), term()}.
class_create(Name, Parent, Length) ->
    {ProtoParent, CtorParent} = case Parent of
        none -> {?OBJECT_PROTO, ?FUNCTION_PROTO};
        null -> {null, ?FUNCTION_PROTO};
        {'$f', _, _} ->
            case get(Parent, <<"prototype">>) of
                PP when ?IS_OBJECT(PP); PP =:= null -> {PP, Parent};
                _ -> type_error(<<"Class extends value does not have valid prototype property">>)
            end;
        _ ->
            type_error(text([<<"Class extends value ">>, describe(Parent), <<" is not a constructor or null">>]))
    end,
    Proto = buoy_heap:new_object(ProtoParent),
    C = buoy_heap:function(fun ?MODULE:class_call/2, Name, Length, #{kind => class, parent => Parent}),
    buoy_heap:set_prototype_of(C, CtorParent),
    buoy_heap:define(C, <<"prototype">>, #{value => Proto, writable => false, enumerable => false, configurable => false}),
    buoy_heap:define(Proto, <<"constructor">>, #{value => C, writable => true, enumerable => false, configurable => true}),
    {C, Proto}.

%% The [[Call]] of a class: a class constructor needs new.
-spec class_call(term(), list()) -> no_return().
class_call(_This, _Args) ->
    type_error(<<"Class constructor cannot be invoked without 'new'">>).

%% The [[Construct]] of a class: fun((NewTarget, Args) -> This).
-spec set_construct(term(), fun((term(), list()) -> term())) -> ok.
set_construct(C, Construct) ->
    buoy_heap:set_slots(C, (buoy_heap:slots(C))#{construct => Construct}).

-spec define_method(term(), buoy_heap:key(), term()) -> term().
define_method(Target, K, F) ->
    buoy_heap:define(Target, K, #{value => F, writable => true, enumerable => false, configurable => true}).

%% A class accessor is not enumerable; an object literal accessor is.
-spec define_getter(term(), buoy_heap:key(), term()) -> term().
define_getter(Target, K, G) -> accessor(Target, K, G, keep, false).

-spec define_setter(term(), buoy_heap:key(), term()) -> term().
define_setter(Target, K, S) -> accessor(Target, K, keep, S, false).

-spec literal_getter(term(), buoy_heap:key(), term()) -> term().
literal_getter(Target, K, G) -> accessor(Target, K, G, keep, true).

-spec literal_setter(term(), buoy_heap:key(), term()) -> term().
literal_setter(Target, K, S) -> accessor(Target, K, keep, S, true).

accessor(Target, K, Getter, Setter, Enumerable) ->
    {OldGetter, OldSetter} = case buoy_heap:get_own(Target, K) of
        {accessor, G, S, _} -> {G, S};
        _ -> {undefined, undefined}
    end,
    buoy_heap:define(Target, K, #{get => keep(Getter, OldGetter), set => keep(Setter, OldSetter),
                                  enumerable => Enumerable, configurable => true}).

keep(keep, Old) -> Old;
keep(New, _Old) -> New.

%% A class field: CreateDataPropertyOrThrow, which ignores setters.
-spec define_field(term(), buoy_heap:key(), term()) -> term().
define_field(O, K, V) ->
    _ = buoy_heap:add_field(O, K, V)
        orelse buoy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true}),
    V.

%%% Literals

-spec array(list()) -> term().
array(Items) -> buoy_heap:new_array(Items).

%% A chunk of the items of a long array literal: the call keeps the Erlang
%% compiler from moving the list to its use, where every item would be live.
-spec chunk(list()) -> list().
chunk(Items) -> Items.

%% An array literal with elisions: each '$hole' is an index without a
%% property, as in [1, , 3].
-spec array_holes(list()) -> term().
array_holes(Items) ->
    A = buoy_heap:new_array(Items),
    [buoy_heap:delete(A, I) || {I, '$hole'} <- lists:enumerate(0, Items)],
    A.

%% [a, ...b]: Parts are {item, V}, {spread, Iterable}, and hole.
-spec array_spread(list()) -> term().
array_spread(Parts) ->
    array_holes(lists:append([spread_part(P) || P <- Parts])).

spread_part({item, V}) -> [V];
spread_part(hole) -> ['$hole'];
spread_part({spread, V}) -> buoy_ref_iterator:to_list(V).

%% {...source} into Target: CopyDataProperties.
-spec object_spread(term(), term()) -> term().
object_spread(Target, Source) when ?IS_OBJECT(Source) ->
    copy_data_properties(Target, Source, []);
object_spread(Target, S) when ?IS_STRING(S) ->
    [define_field(Target, I, buoy_ref_string:unit_string(S, I)) || I <- lists:seq(0, buoy_ref_string:length_of(S) - 1)],
    Target;
object_spread(Target, _Primitive) ->
    Target.

%% const { a, ...rest } = source: the enumerable own properties not named.
-spec object_rest(term(), [buoy_heap:key()]) -> term().
object_rest(Source, Excluded) when ?IS_OBJECT(Source) ->
    copy_data_properties(buoy_heap:new_object(?OBJECT_PROTO), Source, Excluded);
object_rest(_Primitive, _Excluded) ->
    buoy_heap:new_object(?OBJECT_PROTO).

%% CopyDataProperties of an object: the keys in [[OwnPropertyKeys]] order,
%% each excluded key skipped before [[GetOwnProperty]], and Get only when
%% the property is still there and enumerable.
copy_data_properties(Target, Source, Excluded) ->
    lists:foreach(fun(K) ->
                          case not lists:member(K, Excluded) andalso buoy_heap:is_enumerable(buoy_heap:get_own(Source, K)) of
                              true -> define_field(Target, K, get(Source, K));
                              false -> ok
                          end
                  end, buoy_heap:own_keys(Source)),
    Target.

-spec template(list()) -> buoy_ref_string:js_string().
template(Parts) -> text([to_string(P) || P <- Parts]).

%% GetTemplateObject: the frozen array of the cooked strings of a tagged
%% template, with the frozen array of its raw strings as raw. Each site
%% makes it once per realm, so every evaluation of the site gets the same
%% object.
-spec template_object(term(), list(), list()) -> term().
template_object(Site, Cooked, Raw) ->
    Key = {'$buoy_template', Site},
    case erlang:get(Key) of
        undefined ->
            RawArray = buoy_heap:freeze(buoy_heap:new_array(Raw)),
            Template = buoy_heap:new_array(Cooked),
            buoy_heap:define(Template, <<"raw">>, #{value => RawArray, writable => false, enumerable => false, configurable => false}),
            buoy_heap:freeze(Template),
            erlang:put(Key, Template),
            Template;
        Template ->
            Template
    end.

%%% Operators

-spec add(term(), term()) -> term().
add(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:canonical(A + B);
add(A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
add(A, B) when is_number(A), is_number(B) -> buoy_ref_number:add(A, B);
add(A, B) ->
    PA = to_primitive(A, default),
    PB = to_primitive(B, default),
    case ?IS_STRING(PA) orelse ?IS_STRING(PB) of
        true -> buoy_ref_string:concat(to_string(PA), to_string(PB));
        false -> numeric(add, to_numeric(PA), to_numeric(PB))
    end.

%% A numeric operator on the results of ToNumeric: both BigInts, both
%% numbers, or a TypeError for a mix.
numeric(Op, {'$bigint', X}, {'$bigint', Y}) -> buoy_ref_bigint:operate(Op, X, Y);
numeric(_Op, {'$bigint', _}, _) -> mix_error();
numeric(_Op, _, {'$bigint', _}) -> mix_error();
numeric(Op, A, B) -> buoy_ref_number:Op(A, B).

-spec mix_error() -> no_return().
mix_error() -> type_error(<<"Cannot mix BigInt and other types, use explicit conversions">>).

%% ToNumeric of both operands, the left first.
binary_numeric(Op, A, B) ->
    NA = to_numeric(A),
    numeric(Op, NA, to_numeric(B)).

-spec sub(term(), term()) -> term().
sub(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:canonical(A - B);
sub(A, B) when is_number(A), is_number(B) -> buoy_ref_number:sub(A, B);
sub(A, B) -> binary_numeric(sub, A, B).

-spec mul(term(), term()) -> term().
mul(A, B) when is_number(A), is_number(B) -> buoy_ref_number:mul(A, B);
mul(A, B) -> binary_numeric(mul, A, B).

-spec divide(term(), term()) -> term().
divide(A, B) when is_number(A), is_number(B) -> buoy_ref_number:divide(A, B);
divide(A, B) -> binary_numeric(divide, A, B).

-spec remainder(term(), term()) -> term().
remainder(A, B) when is_integer(A), is_integer(B), B > 0, A >= 0 -> A rem B;
remainder(A, B) -> binary_numeric(remainder, A, B).

-spec power(term(), term()) -> term().
power(A, B) -> binary_numeric(power, A, B).

-spec negate(term()) -> term().
negate(A) ->
    case to_numeric(A) of
        {'$bigint', X} -> buoy_ref_bigint:negate(X);
        N -> buoy_ref_number:negate(N)
    end.

-spec plus(term()) -> term().
plus(A) -> to_number(A).

-spec increment(term()) -> term().
increment(A) when is_integer(A) -> buoy_ref_number:canonical(A + 1);
increment(A) -> numeric(add, to_numeric(A), one(A)).

-spec decrement(term()) -> term().
decrement(A) when is_integer(A) -> buoy_ref_number:canonical(A - 1);
decrement(A) -> numeric(sub, to_numeric(A), one(A)).

%% The 1 of the type of a numeric value.
one(N) when ?IS_NUMBER(N) -> 1;
one(V) ->
    case to_numeric(V) of
        {'$bigint', _} -> {'$bigint', 1};
        _ -> 1
    end.

-spec bit_and(term(), term()) -> term().
bit_and(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:bit_and(A, B);
bit_and(A, B) -> binary_numeric(bit_and, A, B).
-spec bit_or(term(), term()) -> term().
bit_or(A, B) when is_integer(A), is_integer(B), A >= 0, A < 16#80000000, B >= 0, B < 16#80000000 -> A bor B;
bit_or(A, B) -> binary_numeric(bit_or, A, B).
-spec bit_xor(term(), term()) -> term().
bit_xor(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:bit_xor(A, B);
bit_xor(A, B) -> binary_numeric(bit_xor, A, B).
-spec bit_not(term()) -> term().
bit_not(A) ->
    case to_numeric(A) of
        {'$bigint', X} -> buoy_ref_bigint:bit_not(X);
        N -> buoy_ref_number:bit_not(N)
    end.
-spec shift_left(term(), term()) -> term().
shift_left(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:shift_left(A, B);
shift_left(A, B) -> binary_numeric(shift_left, A, B).
-spec shift_right(term(), term()) -> term().
shift_right(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:shift_right(A, B);
shift_right(A, B) -> binary_numeric(shift_right, A, B).
-spec shift_right_unsigned(term(), term()) -> term().
shift_right_unsigned(A, B) when is_integer(A), is_integer(B) -> buoy_ref_number:shift_right_unsigned(A, B);
shift_right_unsigned(A, B) -> binary_numeric(shift_right_unsigned, A, B).

%% Objects compare by identity: the terms are equal only for the same id.
-spec strict_eq(term(), term()) -> boolean().
strict_eq(A, B) when is_number(A), is_number(B) -> A == B;
strict_eq(A, B) -> A =/= 'NaN' andalso A =:= B.

%% IsLooselyEqual.
-spec loose_eq(term(), term()) -> boolean().
loose_eq(A, B) when ?IS_OBJECT(A), ?IS_OBJECT(B) -> A =:= B;
loose_eq(A, B) when A =:= undefined; A =:= null -> B =:= undefined orelse B =:= null;
loose_eq(_, B) when B =:= undefined; B =:= null -> false;
loose_eq(A, B) when ?IS_NUMBER(A), ?IS_NUMBER(B) -> strict_eq(A, B);
loose_eq(A, B) when ?IS_STRING(A), ?IS_STRING(B) -> A =:= B;
loose_eq(A, B) when ?IS_NUMBER(A), ?IS_STRING(B) -> strict_eq(A, to_number(B));
loose_eq(A, B) when ?IS_STRING(A), ?IS_NUMBER(B) -> strict_eq(to_number(A), B);
loose_eq({'$bigint', X}, {'$bigint', Y}) -> X =:= Y;
loose_eq({'$bigint', _} = A, B) when ?IS_STRING(B) -> buoy_ref_bigint:from_string(B) =:= A;
loose_eq(A, {'$bigint', _} = B) when ?IS_STRING(A) -> buoy_ref_bigint:from_string(A) =:= B;
loose_eq({'$bigint', X}, B) when ?IS_NUMBER(B) -> buoy_ref_bigint:equals_number(X, B);
loose_eq(A, {'$bigint', Y}) when ?IS_NUMBER(A) -> buoy_ref_bigint:equals_number(Y, A);
loose_eq(A, B) when is_boolean(A) -> loose_eq(to_number(A), B);
loose_eq(A, B) when is_boolean(B) -> loose_eq(A, to_number(B));
loose_eq(A, B) when ?IS_OBJECT(A) -> loose_eq(to_primitive(A, default), B);
loose_eq(A, B) when ?IS_OBJECT(B) -> loose_eq(A, to_primitive(B, default));
loose_eq(A, B) -> A =:= B.

%% The relational operators, from IsLessThan: undefined when a NaN is involved.
-spec lt(term(), term()) -> boolean().
lt(A, B) when is_number(A), is_number(B) -> A < B;
lt(A, B) ->
    {PA, PB} = primitives(A, B),
    less(PA, PB) =:= true.
-spec le(term(), term()) -> boolean().
le(A, B) when is_number(A), is_number(B) -> A =< B;
le(A, B) ->
    {PA, PB} = primitives(A, B),
    less(PB, PA) =:= false.
-spec gt(term(), term()) -> boolean().
gt(A, B) when is_number(A), is_number(B) -> A > B;
gt(A, B) ->
    {PA, PB} = primitives(A, B),
    less(PB, PA) =:= true.
-spec ge(term(), term()) -> boolean().
ge(A, B) when is_number(A), is_number(B) -> A >= B;
ge(A, B) ->
    {PA, PB} = primitives(A, B),
    less(PA, PB) =:= false.

primitives(A, B) ->
    PA = to_primitive(A, number),
    {PA, to_primitive(B, number)}.

less(A, B) when ?IS_STRING(A), ?IS_STRING(B) -> buoy_ref_string:compare(A, B) =:= lt;
less({'$bigint', _} = A, B) when ?IS_STRING(B) -> less_order(A, buoy_ref_bigint:from_string(B));
less(A, {'$bigint', _} = B) when ?IS_STRING(A) -> less_order(buoy_ref_bigint:from_string(A), B);
less(A, B) ->
    NA = to_numeric(A),
    less_order(NA, to_numeric(B)).

less_order(undefined, _) -> undefined;
less_order(_, undefined) -> undefined;
less_order(A, B) ->
    Order = case {A, B} of
        {{'$bigint', X}, {'$bigint', Y}} -> buoy_ref_number:compare(X, Y);
        {{'$bigint', X}, _} -> buoy_ref_bigint:compare_number(X, B);
        {_, {'$bigint', Y}} -> invert(buoy_ref_bigint:compare_number(Y, A));
        _ -> buoy_ref_number:compare(A, B)
    end,
    case Order of
        undefined -> undefined;
        _ -> Order =:= lt
    end.

invert(lt) -> gt;
invert(gt) -> lt;
invert(Order) -> Order.

-spec typeof(term()) -> binary().
typeof({'$f', _, _}) -> <<"function">>;
typeof({'$o', _}) -> <<"object">>;
typeof({'$sym', _, _}) -> <<"symbol">>;
typeof({'$actor', _}) -> <<"object">>;
typeof(undefined) -> <<"undefined">>;
typeof(null) -> <<"object">>;
typeof(B) when is_boolean(B) -> <<"boolean">>;
typeof(N) when ?IS_NUMBER(N) -> <<"number">>;
typeof({'$bigint', _}) -> <<"bigint">>;
typeof(S) when ?IS_STRING(S) -> <<"string">>.

%% `typeof name` for a name that no scope declares: "undefined" for a missing global.
-spec typeof_global(binary()) -> binary().
typeof_global(Name) ->
    case buoy_ref_realm:has_binding(Name) of
        true -> typeof(global(Name));
        false -> <<"undefined">>
    end.

%% InstanceofOperator: Symbol.hasInstance, else OrdinaryHasInstance.
-spec instance_of(term(), term()) -> boolean().
instance_of(V, C) when ?IS_OBJECT(C) ->
    case get(C, ?SYM(hasInstance)) of
        {'$f', {builtin, <<"Function.prototype[Symbol.hasInstance]">>}, _} ->
            buoy_ref_function:ordinary_has_instance(C, V);
        H when H =:= undefined; H =:= null ->
            buoy_heap:is_callable(C) orelse type_error(text([<<"Right-hand side of 'instanceof' is not callable">>])),
            buoy_ref_function:ordinary_has_instance(C, V);
        H ->
            truthy(call(H, C, [V]))
    end;
instance_of(_V, C) ->
    type_error(text([<<"Right-hand side of 'instanceof' is not an object (">>, describe(C), <<")">>])).

-spec truthy(term()) -> boolean().
truthy(true) -> true;
truthy(false) -> false;
truthy(undefined) -> false;
truthy(null) -> false;
truthy(0) -> false;
truthy(<<>>) -> false;
truthy(F) when is_float(F) -> F /= 0;
truthy('NaN') -> false;
truthy({'$bigint', 0}) -> false;
truthy(_) -> true.

%%% Conversions

-spec to_string(term()) -> buoy_ref_string:js_string().
to_string(S) when ?IS_STRING(S) -> S;
to_string(N) when ?IS_NUMBER(N) -> buoy_ref_number:to_string(N);
to_string(true) -> <<"true">>;
to_string(false) -> <<"false">>;
to_string(undefined) -> <<"undefined">>;
to_string(null) -> <<"null">>;
to_string(V) when ?IS_OBJECT(V) -> to_string(to_primitive(V, string));
to_string({'$sym', _, _}) -> type_error(<<"Cannot convert a Symbol value to a string">>);
to_string({'$bigint', I}) -> integer_to_binary(I);
to_string({'$actor', _}) -> <<"[object ActorRef]">>.

-spec to_number(term()) -> term().
to_number(N) when ?IS_NUMBER(N) -> N;
to_number(S) when ?IS_STRING(S) -> buoy_ref_number:from_string(S);
to_number(true) -> 1;
to_number(false) -> 0;
to_number(null) -> 0;
to_number(undefined) -> 'NaN';
to_number(V) when ?IS_OBJECT(V) -> to_number(to_primitive(V, number));
to_number({'$sym', _, _}) -> type_error(<<"Cannot convert a Symbol value to a number">>);
to_number({'$bigint', _}) -> type_error(<<"Cannot convert a BigInt value to a number">>);
to_number(_) -> 'NaN'.

%% ToNumeric: a number, or a BigInt.
-spec to_numeric(term()) -> term().
to_numeric(N) when ?IS_NUMBER(N) -> N;
to_numeric({'$bigint', _} = B) -> B;
to_numeric(V) when ?IS_OBJECT(V) -> to_numeric(to_primitive(V, number));
to_numeric(V) -> to_number(V).

%% ToObject: an object as it is, else the wrapper object of a primitive.
-spec to_object(term()) -> term().
to_object(V) when ?IS_OBJECT(V) -> V;
to_object(V) when V =:= undefined; V =:= null -> type_error(<<"Cannot convert undefined or null to object">>);
to_object(N) when ?IS_NUMBER(N) -> buoy_ref_number:wrap(N, buoy_heap:intrinsic('Number.prototype'));
to_object(S) when ?IS_STRING(S) -> buoy_ref_string:wrap(S, buoy_heap:intrinsic('String.prototype'));
to_object(B) when is_boolean(B) -> buoy_ref_boolean:wrap(B, buoy_heap:intrinsic('Boolean.prototype'));
to_object({'$bigint', _} = B) -> buoy_ref_bigint:wrap(B, buoy_heap:intrinsic('BigInt.prototype'));
to_object({'$sym', _, _} = S) -> buoy_heap:new_exotic(symbol, buoy_heap:intrinsic('Symbol.prototype'), S);
to_object(V) -> V.

%% ToPrimitive: Symbol.toPrimitive, else valueOf and toString in the order
%% of the hint.
-spec to_primitive(term(), default | string | number) -> term().
to_primitive(V, Hint) when ?IS_OBJECT(V) ->
    case get(V, buoy_heap:well_known(toPrimitive)) of
        {'$f', _, _} = Exotic ->
            primitive_or_fail(call(Exotic, V, [atom_to_binary(Hint)]));
        Method when Method =/= undefined, Method =/= null ->
            type_error(<<"Symbol.toPrimitive is not a function">>);
        _ ->
            Order = case Hint of
                string -> [<<"toString">>, <<"valueOf">>];
                _ -> [<<"valueOf">>, <<"toString">>]
            end,
            ordinary_primitive(V, Order)
    end;
to_primitive(V, _Hint) ->
    V.

ordinary_primitive(_V, []) ->
    type_error(<<"Cannot convert object to primitive value">>);
ordinary_primitive(V, [Name | Rest]) ->
    case get(V, Name) of
        {'$f', _, _} = F ->
            case call(F, V, []) of
                R when ?IS_OBJECT(R) -> ordinary_primitive(V, Rest);
                R -> R
            end;
        _ ->
            ordinary_primitive(V, Rest)
    end.

primitive_or_fail(R) when ?IS_OBJECT(R) -> type_error(<<"Cannot convert object to primitive value">>);
primitive_or_fail(R) -> R.

-spec describe(term()) -> buoy_ref_string:js_string().
describe(undefined) -> <<"undefined">>;
describe(null) -> <<"null">>;
describe(V) when ?IS_STRING(V) -> text([<<"\"">>, V, <<"\"">>]);
describe({'$f', _, _} = F) ->
    case get(F, <<"name">>) of
        <<>> -> <<"function">>;
        Name when ?IS_STRING(Name) -> Name;
        _ -> <<"function">>
    end;
describe({'$o', _}) -> <<"#<Object>">>;
describe({'$sym', _, _} = S) -> key_text(S);
describe({'$actor', _}) -> <<"ActorRef">>;
describe(V) -> to_string(V).

%%% Actors

%% The constructor arguments of spawn(Class, { args }).
-spec spawn_args(term()) -> list().
spawn_args(undefined) -> [];
spawn_args(Options) ->
    case get(Options, <<"args">>) of
        undefined -> [];
        Args -> buoy_ref_iterator:to_list(Args)
    end.

-spec stop_actor(list()) -> undefined.
stop_actor([{'$actor', Pid} | _]) -> buoy_jobs:stop_actor(Pid);
stop_actor(_) -> type_error(<<"stop() needs an actor ref">>).

%% heapStats() from "buoy": the heap and the collector of this realm, for the benchmarks.
-spec heap_stats() -> term().
heap_stats() ->
    #{runs := Runs, total_us := Total, max_us := Max} = Stats = buoy_heap:gc_stats(),
    {memory, Bytes} = erlang:process_info(self(), memory),
    buoy_heap:object(?OBJECT_PROTO, [{<<"entries">>, buoy_heap:heap_size()}, {<<"allocated">>, buoy_heap:allocated()},
                                     {<<"live">>, maps:get(live, Stats, 0)}, {<<"gcRuns">>, Runs},
                                     {<<"gcTotalUs">>, Total}, {<<"gcMaxUs">>, Max}, {<<"processBytes">>, Bytes}]).

%% vmMemory() from "buoy": erlang:memory(total) and the process count.
-spec vm_memory() -> term().
vm_memory() ->
    buoy_heap:object(?OBJECT_PROTO, [{<<"total">>, erlang:memory(total)}, {<<"processes">>, erlang:memory(processes)},
                                     {<<"processCount">>, erlang:system_info(process_count)}]).



