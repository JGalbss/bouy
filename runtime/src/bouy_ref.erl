%% The operations that compiled reference-semantics code calls.
%%
%% Values are undefined, null, booleans, numbers (bouy_ref_number), strings
%% (bouy_ref_string), the heap values of bouy_heap (objects, functions, and
%% symbols), and {'$actor', Pid} for an actor ref. Property reads on a
%% primitive go to the intrinsic prototype of its type, as in JavaScript.
-module(bouy_ref).

-export([init_realm/0, global/1, caught/2, report_uncaught/1, exit_program/1, stderr/0, type_error/1]).
-export_type([exit_status/0]).

-type exit_status() :: 0..255.
-export([get/2, get_computed/2, set/3, set_computed/3, delete/2, delete_computed/2, in/2, to_property_key/1]).
-export([call/3, call_method/3, call_method_computed/3, construct/2, new_this/1, super_construct/3, super_get/3, super_call/4]).
-export([arguments_object/1, throw_type_error/2, fn/1, named_fn/3, class_create/3, set_construct/2, define_method/3, define_getter/3, define_setter/3, define_field/3]).
-export([literal_getter/3, literal_setter/3, class_call/2]).
-export([array/1, array_spread/1, object_spread/2, object_rest/2, template/1]).
-export([add/2, sub/2, mul/2, divide/2, remainder/2, power/2, negate/1, plus/1]).
-export([bit_and/2, bit_or/2, bit_xor/2, bit_not/1, shift_left/2, shift_right/2, shift_right_unsigned/2]).
-export([strict_eq/2, loose_eq/2, lt/2, le/2, gt/2, ge/2, typeof/1, instance_of/2, truthy/1]).
-export([to_string/1, to_number/1, to_primitive/2, increment/1, decrement/1]).
-export([describe/1, typeof_global/1, spawn_args/1, stop_actor/1, heap_stats/0, vm_memory/0]).

-include("bouy_ref.hrl").

%%% Realm

%% Installs the static intrinsics once per VM. Each realm starts empty: its
%% intrinsics read through to the static records until the realm writes one.
-spec init_realm() -> ok.
init_realm() -> bouy_ref_realm:install().

-spec global(binary()) -> term().
global(Name) -> bouy_ref_realm:global(Name).

%%% Errors

-spec type_error(bouy_ref_string:js_string()) -> no_return().
type_error(Message) -> bouy_heap:throw_error('TypeError', Message).

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
    Message = bouy_ref_string:from_utf8(unicode:characters_to_binary(io_lib:format("~0tP~s", [Reason, 8, Where]))),
    bouy_heap:error_object('TypeError', Message, text([<<"TypeError: ">>, Message])).

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
%% '$bouy_exit' in its process dictionary: the realm then exits with
%% {'$bouy_exit', Status}, and the VM goes on.
-spec exit_program(exit_status()) -> no_return().
exit_program(Status) ->
    case erlang:get('$bouy_exit') of
        undefined -> erlang:halt(Status);
        _ -> exit({'$bouy_exit', Status})
    end.

%% The device of stderr: '$bouy_stderr' in the process dictionary of a realm
%% that a test runner starts, else standard_error.
-spec stderr() -> io:device().
stderr() ->
    case erlang:get('$bouy_stderr') of
        undefined -> standard_error;
        Device -> Device
    end.

uncaught_text({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        error -> bouy_ref_string:to_utf8(to_string(O));
        _ -> bouy_ref_console:inspect(O)
    end;
uncaught_text(V) ->
    bouy_ref_console:inspect(V).

%%% Properties

-spec get(term(), bouy_heap:key()) -> term().
get({'$o', _} = O, K) -> bouy_heap:get(O, K);
get({'$f', _, _} = F, K) -> bouy_heap:get(F, K);
get(S, K) when ?IS_STRING(S) -> bouy_ref_string:get(S, K);
get(undefined, K) -> read_error(<<"undefined">>, K);
get(null, K) -> read_error(<<"null">>, K);
get(B, K) when is_boolean(B) -> bouy_heap:get({'$o', 'Boolean.prototype'}, K);
get(N, K) when ?IS_NUMBER(N) -> bouy_heap:get({'$o', 'Number.prototype'}, K);
get({'$sym', _, Description}, <<"description">>) -> Description;
get({'$sym', _, _}, K) -> bouy_heap:get({'$o', 'Symbol.prototype'}, K);
get({'$actor', Pid}, K) when ?IS_STRING(K) -> {'$f', {actor, Pid, K}, fun(_This, Args) -> bouy_jobs:actor_call(Pid, K, Args) end};
get({'$actor', _}, _K) -> undefined.

-spec read_error(binary(), bouy_heap:key()) -> no_return().
read_error(What, K) ->
    type_error(text([<<"Cannot read properties of ">>, What, <<" (reading '">>, key_text(K), <<"')">>])).

%% A message from strings of the engine.
text(Parts) -> bouy_ref_string:concat(Parts).

-spec get_computed(term(), term()) -> term().
get_computed(O, K) -> get(O, to_property_key(K)).

-spec set(term(), bouy_heap:key(), term()) -> term().
set({'$o', _} = O, K, V) -> bouy_heap:set(O, K, V);
set({'$f', _, _} = F, K, V) -> bouy_heap:set(F, K, V);
set(undefined, K, _V) -> type_error(text([<<"Cannot set properties of undefined (setting '">>, key_text(K), <<"')">>]));
set(null, K, _V) -> type_error(text([<<"Cannot set properties of null (setting '">>, key_text(K), <<"')">>]));
set(P, K, _V) -> type_error(text([<<"Cannot create property '">>, key_text(K), <<"' on ">>, typeof(P), <<" '">>, to_string(P), <<"'">>])).

-spec set_computed(term(), term(), term()) -> term().
set_computed(O, K, V) -> set(O, to_property_key(K), V).

-spec delete(term(), bouy_heap:key()) -> boolean().
delete(O, K) when ?IS_OBJECT(O) -> bouy_heap:delete(O, K);
delete(undefined, K) -> type_error(text([<<"Cannot convert undefined or null to object (deleting '">>, key_text(K), <<"')">>]));
delete(null, K) -> delete(undefined, K);
delete(_P, _K) -> true.

-spec delete_computed(term(), term()) -> boolean().
delete_computed(O, K) -> delete(O, to_property_key(K)).

%% `k in o`.
-spec in(term(), term()) -> boolean().
in(K, O) when ?IS_OBJECT(O) -> bouy_heap:has(O, to_property_key(K));
in(K, O) -> type_error(text([<<"Cannot use 'in' operator to search for '">>, to_string(K), <<"' in ">>, describe(O)])).

-spec to_property_key(term()) -> bouy_heap:key().
to_property_key(K) when ?IS_OBJECT(K) -> bouy_heap:to_key(to_primitive(K, string));
to_property_key(K) -> bouy_heap:to_key(K).

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
-spec call_method(term(), bouy_heap:key(), list()) -> term().
call_method({'$o', _} = O, K, Args) -> invoke(bouy_heap:get(O, K), O, K, Args);
call_method({'$actor', Pid}, K, Args) -> bouy_jobs:actor_call(Pid, K, Args);
call_method(R, K, Args) -> invoke(get(R, K), R, K, Args).

invoke({'$f', _, Fun}, This, _K, Args) -> Fun(This, Args);
invoke(_V, This, K, _Args) -> type_error(text([receiver_text(This), <<".">>, key_text(K), <<" is not a function">>])).

receiver_text(V) when ?IS_OBJECT(V) -> <<"object">>;
receiver_text(V) -> describe(V).

-spec call_method_computed(term(), term(), list()) -> term().
call_method_computed(R, K, Args) -> call_method(R, to_property_key(K), Args).

-spec construct(term(), list()) -> term().
construct(F, Args) -> bouy_heap:construct(F, Args, F).

%% The this of a base class constructor: an object whose prototype is the
%% prototype of new.target.
-spec new_this(term()) -> term().
new_this(NewTarget) ->
    Proto = case get(NewTarget, <<"prototype">>) of
        P when ?IS_OBJECT(P) -> P;
        _ -> ?OBJECT_PROTO
    end,
    bouy_heap:new_object(Proto).

-spec super_construct(term(), list(), term()) -> term().
super_construct(Parent, Args, NewTarget) -> bouy_heap:construct(Parent, Args, NewTarget).

%% super.k inside a method whose home object is Home, with this as receiver.
-spec super_get(term(), bouy_heap:key(), term()) -> term().
super_get(Home, K, This) -> lookup(bouy_heap:prototype_of(Home), K, This).

lookup(null, _K, _Receiver) ->
    undefined;
lookup(O, K, Receiver) ->
    case bouy_heap:get_own(O, K) of
        {data, V, _} -> V;
        {accessor, undefined, _, _} -> undefined;
        {accessor, G, _, _} -> call(G, Receiver, []);
        none -> lookup(bouy_heap:prototype_of(O), K, Receiver)
    end.

-spec super_call(term(), bouy_heap:key(), term(), list()) -> term().
super_call(Home, K, This, Args) -> invoke(super_get(Home, K, This), This, K, Args).

%%% Functions and classes

%% The unmapped arguments object of a function call, as in strict code: the
%% arguments by index, length, the array iterator, and a callee that throws.
-spec arguments_object(list()) -> term().
arguments_object(Args) ->
    O = bouy_heap:new_exotic(arguments, ?OBJECT_PROTO, none),
    [bouy_heap:define(O, I, #{value => V, writable => true, enumerable => true, configurable => true}) || {I, V} <- lists:enumerate(0, Args)],
    bouy_heap:define(O, <<"length">>, #{value => length(Args), writable => true, enumerable => false, configurable => true}),
    bouy_heap:define(O, ?SYM(iterator), #{value => bouy_heap:get({'$o', 'Array.prototype'}, <<"values">>),
                                          writable => true, enumerable => false, configurable => true}),
    Thrower = bouy_ref_realm:builtin(<<"ThrowTypeError">>, fun ?MODULE:throw_type_error/2),
    bouy_heap:define(O, <<"callee">>, #{get => Thrower, set => Thrower, enumerable => false, configurable => false}),
    O.

%% %ThrowTypeError%: the accessor of callee on an arguments object.
-spec throw_type_error(term(), list()) -> no_return().
throw_type_error(_This, _Args) ->
    type_error(<<"'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them">>).

%% An arrow function or a method: no record until something needs one.
-spec fn(fun((term(), list()) -> term())) -> term().
fn(Fun) -> bouy_heap:function(Fun).

%% A function declaration or expression: it has a name and a prototype
%% object, so new works on it.
-spec named_fn(fun((term(), list()) -> term()), binary(), non_neg_integer()) -> term().
named_fn(Fun, Name, Length) ->
    F = bouy_heap:function(Fun, Name, Length, #{kind => normal}),
    Proto = bouy_heap:new_object(?OBJECT_PROTO),
    bouy_heap:define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
    bouy_heap:define(F, <<"prototype">>, #{value => Proto, writable => true, enumerable => false, configurable => false}),
    F.

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
    Proto = bouy_heap:new_object(ProtoParent),
    C = bouy_heap:function(fun ?MODULE:class_call/2, Name, Length, #{kind => class, parent => Parent}),
    bouy_heap:set_prototype_of(C, CtorParent),
    bouy_heap:define(C, <<"prototype">>, #{value => Proto, writable => false, enumerable => false, configurable => false}),
    bouy_heap:define(Proto, <<"constructor">>, #{value => C, writable => true, enumerable => false, configurable => true}),
    {C, Proto}.

%% The [[Call]] of a class: a class constructor needs new.
-spec class_call(term(), list()) -> no_return().
class_call(_This, _Args) ->
    type_error(<<"Class constructor cannot be invoked without 'new'">>).

%% The [[Construct]] of a class: fun((NewTarget, Args) -> This).
-spec set_construct(term(), fun((term(), list()) -> term())) -> ok.
set_construct(C, Construct) ->
    bouy_heap:set_slots(C, (bouy_heap:slots(C))#{construct => Construct}).

-spec define_method(term(), bouy_heap:key(), term()) -> term().
define_method(Target, K, F) ->
    bouy_heap:define(Target, K, #{value => F, writable => true, enumerable => false, configurable => true}).

%% A class accessor is not enumerable; an object literal accessor is.
-spec define_getter(term(), bouy_heap:key(), term()) -> term().
define_getter(Target, K, G) -> accessor(Target, K, G, keep, false).

-spec define_setter(term(), bouy_heap:key(), term()) -> term().
define_setter(Target, K, S) -> accessor(Target, K, keep, S, false).

-spec literal_getter(term(), bouy_heap:key(), term()) -> term().
literal_getter(Target, K, G) -> accessor(Target, K, G, keep, true).

-spec literal_setter(term(), bouy_heap:key(), term()) -> term().
literal_setter(Target, K, S) -> accessor(Target, K, keep, S, true).

accessor(Target, K, Getter, Setter, Enumerable) ->
    {OldGetter, OldSetter} = case bouy_heap:get_own(Target, K) of
        {accessor, G, S, _} -> {G, S};
        _ -> {undefined, undefined}
    end,
    bouy_heap:define(Target, K, #{get => keep(Getter, OldGetter), set => keep(Setter, OldSetter),
                                  enumerable => Enumerable, configurable => true}).

keep(keep, Old) -> Old;
keep(New, _Old) -> New.

%% A class field: CreateDataPropertyOrThrow, which ignores setters.
-spec define_field(term(), bouy_heap:key(), term()) -> term().
define_field(O, K, V) ->
    bouy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true}),
    V.

%%% Literals

-spec array(list()) -> term().
array(Items) -> bouy_heap:new_array(Items).

%% [a, ...b]: Parts are {item, V} and {spread, Iterable}.
-spec array_spread(list()) -> term().
array_spread(Parts) ->
    bouy_heap:new_array(lists:append([spread_part(P) || P <- Parts])).

spread_part({item, V}) -> [V];
spread_part({spread, V}) -> bouy_ref_iterator:to_list(V).

%% {...source} into Target: CopyDataProperties.
-spec object_spread(term(), term()) -> term().
object_spread(Target, Source) when ?IS_OBJECT(Source) ->
    [define_field(Target, K, get(Source, K)) || K <- own_enumerable_keys(Source)],
    Target;
object_spread(Target, S) when ?IS_STRING(S) ->
    [define_field(Target, I, bouy_ref_string:unit_string(S, I)) || I <- lists:seq(0, bouy_ref_string:length_of(S) - 1)],
    Target;
object_spread(Target, _Primitive) ->
    Target.

own_enumerable_keys(O) ->
    Enumerable = bouy_heap:enumerable_keys(O),
    Symbols = [K || {'$sym', _, _} = K <- bouy_heap:own_keys(O), is_enumerable(O, K)],
    Enumerable ++ Symbols.

is_enumerable(O, K) ->
    case bouy_heap:get_own(O, K) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end.

%% const { a, ...rest } = source: the enumerable own properties not named.
-spec object_rest(term(), [bouy_heap:key()]) -> term().
object_rest(Source, Excluded) ->
    Rest = bouy_heap:new_object(?OBJECT_PROTO),
    case ?IS_OBJECT(Source) of
        true -> [define_field(Rest, K, get(Source, K)) || K <- own_enumerable_keys(Source), not lists:member(K, Excluded)];
        false -> ok
    end,
    Rest.

-spec template(list()) -> bouy_ref_string:js_string().
template(Parts) -> text([to_string(P) || P <- Parts]).

%%% Operators

-spec add(term(), term()) -> term().
add(A, B) when is_integer(A), is_integer(B) -> bouy_ref_number:canonical(A + B);
add(A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
add(A, B) ->
    PA = to_primitive(A, default),
    PB = to_primitive(B, default),
    case ?IS_STRING(PA) orelse ?IS_STRING(PB) of
        true -> bouy_ref_string:concat(to_string(PA), to_string(PB));
        false -> bouy_ref_number:add(to_number(PA), to_number(PB))
    end.

%% ToNumeric for the operators, which take no BigInt yet.
num(N) when ?IS_NUMBER(N) -> N;
num(V) -> to_number(V).

-spec sub(term(), term()) -> term().
sub(A, B) when is_integer(A), is_integer(B) -> bouy_ref_number:canonical(A - B);
sub(A, B) ->
    NA = num(A),
    bouy_ref_number:sub(NA, num(B)).

-spec mul(term(), term()) -> term().
mul(A, B) ->
    NA = num(A),
    bouy_ref_number:mul(NA, num(B)).

-spec divide(term(), term()) -> term().
divide(A, B) ->
    NA = num(A),
    bouy_ref_number:divide(NA, num(B)).

-spec remainder(term(), term()) -> term().
remainder(A, B) when is_integer(A), is_integer(B), B > 0, A >= 0 -> A rem B;
remainder(A, B) ->
    NA = num(A),
    bouy_ref_number:remainder(NA, num(B)).

-spec power(term(), term()) -> term().
power(A, B) ->
    NA = num(A),
    bouy_ref_number:power(NA, num(B)).

-spec negate(term()) -> term().
negate(A) -> bouy_ref_number:negate(num(A)).

-spec plus(term()) -> term().
plus(A) -> to_number(A).

-spec increment(term()) -> term().
increment(A) when is_integer(A) -> bouy_ref_number:canonical(A + 1);
increment(A) -> bouy_ref_number:add(num(A), 1).

-spec decrement(term()) -> term().
decrement(A) when is_integer(A) -> bouy_ref_number:canonical(A - 1);
decrement(A) -> bouy_ref_number:sub(num(A), 1).

-spec bit_and(term(), term()) -> integer().
bit_and(A, B) ->
    NA = num(A),
    bouy_ref_number:bit_and(NA, num(B)).
-spec bit_or(term(), term()) -> integer().
bit_or(A, B) ->
    NA = num(A),
    bouy_ref_number:bit_or(NA, num(B)).
-spec bit_xor(term(), term()) -> integer().
bit_xor(A, B) ->
    NA = num(A),
    bouy_ref_number:bit_xor(NA, num(B)).
-spec bit_not(term()) -> integer().
bit_not(A) -> bouy_ref_number:bit_not(num(A)).
-spec shift_left(term(), term()) -> integer().
shift_left(A, B) ->
    NA = num(A),
    bouy_ref_number:shift_left(NA, num(B)).
-spec shift_right(term(), term()) -> integer().
shift_right(A, B) ->
    NA = num(A),
    bouy_ref_number:shift_right(NA, num(B)).
-spec shift_right_unsigned(term(), term()) -> integer().
shift_right_unsigned(A, B) ->
    NA = num(A),
    bouy_ref_number:shift_right_unsigned(NA, num(B)).

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

less(A, B) when ?IS_STRING(A), ?IS_STRING(B) -> bouy_ref_string:compare(A, B) =:= lt;
less(A, B) ->
    NA = num(A),
    case bouy_ref_number:compare(NA, num(B)) of
        undefined -> undefined;
        Order -> Order =:= lt
    end.

-spec typeof(term()) -> binary().
typeof({'$f', _, _}) -> <<"function">>;
typeof({'$o', _}) -> <<"object">>;
typeof({'$sym', _, _}) -> <<"symbol">>;
typeof({'$actor', _}) -> <<"object">>;
typeof(undefined) -> <<"undefined">>;
typeof(null) -> <<"object">>;
typeof(B) when is_boolean(B) -> <<"boolean">>;
typeof(N) when ?IS_NUMBER(N) -> <<"number">>;
typeof(S) when ?IS_STRING(S) -> <<"string">>.

%% `typeof name` for a name that no scope declares: "undefined" for a missing global.
-spec typeof_global(binary()) -> binary().
typeof_global(Name) ->
    try typeof(global(Name))
    catch
        error:{'$throw', _} -> <<"undefined">>
    end.

%% InstanceofOperator: a Symbol.hasInstance method of the target decides,
%% such as a static method of a class; else OrdinaryHasInstance.
-spec instance_of(term(), term()) -> boolean().
instance_of(V, C) when ?IS_OBJECT(C) ->
    case get(C, bouy_heap:well_known(hasInstance)) of
        H when H =:= undefined; H =:= null -> ordinary_instance_of(V, C);
        H -> truthy(call(H, C, [V]))
    end;
instance_of(V, C) ->
    ordinary_instance_of(V, C).

ordinary_instance_of(V, {'$f', _, _} = C) ->
    case ?IS_OBJECT(V) of
        false ->
            false;
        true ->
            Proto = get(C, <<"prototype">>),
            ?IS_OBJECT(Proto) orelse type_error(<<"Function has non-object prototype in instanceof check">>),
            in_chain(bouy_heap:prototype_of(V), Proto)
    end;
ordinary_instance_of(_V, C) ->
    type_error(text([<<"Right-hand side of 'instanceof' is not callable (">>, describe(C), <<")">>])).

in_chain(null, _Proto) -> false;
in_chain(Proto, Proto) -> true;
in_chain(O, Proto) -> in_chain(bouy_heap:prototype_of(O), Proto).

-spec truthy(term()) -> boolean().
truthy(true) -> true;
truthy(false) -> false;
truthy(undefined) -> false;
truthy(null) -> false;
truthy(0) -> false;
truthy(<<>>) -> false;
truthy(F) when is_float(F) -> F /= 0;
truthy('NaN') -> false;
truthy(_) -> true.

%%% Conversions

-spec to_string(term()) -> bouy_ref_string:js_string().
to_string(S) when ?IS_STRING(S) -> S;
to_string(N) when ?IS_NUMBER(N) -> bouy_ref_number:to_string(N);
to_string(true) -> <<"true">>;
to_string(false) -> <<"false">>;
to_string(undefined) -> <<"undefined">>;
to_string(null) -> <<"null">>;
to_string(V) when ?IS_OBJECT(V) -> to_string(to_primitive(V, string));
to_string({'$sym', _, _}) -> type_error(<<"Cannot convert a Symbol value to a string">>);
to_string({'$actor', _}) -> <<"[object ActorRef]">>.

-spec to_number(term()) -> term().
to_number(N) when ?IS_NUMBER(N) -> N;
to_number(S) when ?IS_STRING(S) -> bouy_ref_number:from_string(S);
to_number(true) -> 1;
to_number(false) -> 0;
to_number(null) -> 0;
to_number(undefined) -> 'NaN';
to_number(V) when ?IS_OBJECT(V) -> to_number(to_primitive(V, number));
to_number({'$sym', _, _}) -> type_error(<<"Cannot convert a Symbol value to a number">>);
to_number(_) -> 'NaN'.

%% ToPrimitive: Symbol.toPrimitive, else valueOf and toString in the order
%% of the hint.
-spec to_primitive(term(), default | string | number) -> term().
to_primitive(V, Hint) when ?IS_OBJECT(V) ->
    case get(V, bouy_heap:well_known(toPrimitive)) of
        {'$f', _, _} = Exotic ->
            primitive_or_fail(call(Exotic, V, [atom_to_binary(Hint)]));
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

-spec describe(term()) -> bouy_ref_string:js_string().
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
        Args -> bouy_ref_iterator:to_list(Args)
    end.

-spec stop_actor(list()) -> undefined.
stop_actor([{'$actor', Pid} | _]) -> bouy_jobs:stop_actor(Pid);
stop_actor(_) -> type_error(<<"stop() needs an actor ref">>).

%% heapStats() from "bouy": the heap and the collector of this realm, for the benchmarks.
-spec heap_stats() -> term().
heap_stats() ->
    #{runs := Runs, total_us := Total, max_us := Max} = Stats = bouy_heap:gc_stats(),
    {memory, Bytes} = erlang:process_info(self(), memory),
    bouy_heap:object(?OBJECT_PROTO, [{<<"entries">>, bouy_heap:heap_size()}, {<<"allocated">>, bouy_heap:allocated()},
                                     {<<"live">>, maps:get(live, Stats, 0)}, {<<"gcRuns">>, Runs},
                                     {<<"gcTotalUs">>, Total}, {<<"gcMaxUs">>, Max}, {<<"processBytes">>, Bytes}]).

%% vmMemory() from "bouy": erlang:memory(total) and the process count.
-spec vm_memory() -> term().
vm_memory() ->
    bouy_heap:object(?OBJECT_PROTO, [{<<"total">>, erlang:memory(total)}, {<<"processes">>, erlang:memory(processes)},
                                     {<<"processCount">>, erlang:system_info(process_count)}]).



