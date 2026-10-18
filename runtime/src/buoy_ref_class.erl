%% Classes of the reference-semantics engine: ClassDefinitionEvaluation, the
%% function objects of methods, the this binding of a derived constructor,
%% super, and private names.
%%
%% A private name is {'#', Unique, Name}: each evaluation of a class body makes
%% new ones, so two evaluations of one class expression do not share them. A
%% private element lives in the Props of its object under its name, which is
%% never an own key that reflection returns (buoy_heap:private_find/2). Its
%% slot is the value of a field, {'$method', F}, or {'$accessor', Get, Set}.
-module(buoy_ref_class).

-include("buoy_ref.hrl").

-export([create/4, set_construct/2, method/4, method/5, function_name/2, define_field/3, define_method/4]).
-export([base_return/2, initialized/2, set_module/3]).
-export([super_construct/3, construct_parent/3, this_of/1, bind_this/2, derived_return/2, new_target_construct/3]).
-export([super_get/3, super_set/4, sloppy_super_set/4]).
-export([private_name/1, private_names/1, private_get/2, private_set/3, private_in/2, private_add/3, add_private_methods/2]).

-define(UNINITIALIZED, '$uninitialized').
-define(CONSTRUCT_ERROR, '$buoy_construct_error').

%%% Class definition

%% The constructor and the prototype of a class, up to its elements. Parent
%% is none without extends. Source is where the source text of the class is,
%% {Module, Start, End}, for Function.prototype.toString.
-spec create(term(), term(), non_neg_integer(), {module(), non_neg_integer(), non_neg_integer()}) -> {term(), term()}.
create(Name, Parent, Length, Source) ->
    {ProtoParent, CtorParent} = case Parent of
        none -> {?OBJECT_PROTO, ?FUNCTION_PROTO};
        null -> {null, ?FUNCTION_PROTO};
        _ ->
            is_constructor(Parent) orelse
                buoy_ref:type_error(buoy_ref_string:concat([<<"Class extends value ">>, buoy_ref:describe(Parent), <<" is not a constructor or null">>])),
            case buoy_ref:get(Parent, <<"prototype">>) of
                PP when ?IS_OBJECT(PP); PP =:= null -> {PP, Parent};
                _ -> buoy_ref:type_error(<<"Class extends value does not have valid prototype property">>)
            end
    end,
    Proto = buoy_heap:new_object(ProtoParent),
    Slots = #{kind => class, derived => Parent =/= none, source => Source},
    C = buoy_heap:function(fun buoy_ref:class_call/2, function_name(Name, <<>>), Length, Slots),
    buoy_heap:set_prototype_of(C, CtorParent),
    buoy_heap:define(C, <<"prototype">>, #{value => Proto, writable => false, enumerable => false, configurable => false}),
    buoy_heap:define(Proto, <<"constructor">>, #{value => C, writable => true, enumerable => false, configurable => true}),
    {C, Proto}.

%% The [[Construct]] of the class C: fun((NewTarget, Args) -> This).
-spec set_construct(term(), fun((term(), list()) -> term())) -> ok.
set_construct(C, Construct) ->
    Slots = buoy_heap:slots(C),
    Construct1 = case Slots of
        #{realm := N} -> buoy_ref_realm:realm_fun(N, Construct);
        _ -> Construct
    end,
    buoy_heap:set_slots(C, Slots#{construct => fun(NewTarget, Args) -> constructed(Construct1(NewTarget, Args)) end}).

%% [[Construct]] throws the errors of a derived constructor's result after it
%% leaves the constructor, so in the realm of the caller (ECMA-262 §10.2.2).
constructed({?CONSTRUCT_ERROR, Name, Message}) -> buoy_heap:throw_error(Name, Message);
constructed(V) -> V.

is_constructor(F) -> buoy_heap:is_constructor(F).

%% The function object of a method, an accessor, or another function that
%% NamedEvaluation names from a property key. Kind is method, get, set,
%% arrow, async, generator, or async_generator. A generator kind takes a
%% maker, fun((SelfId) -> Fun), so that its body can find its own prototype.
-spec method(term(), term(), non_neg_integer(), atom()) -> term().
method(Fun, Key, Length, Kind) ->
    buoy_ref_generator:function(Fun, function_name(Key, prefix(Kind)), Length, Kind).

%% method/4 with the place of its source text, {Module, Start, End}, for
%% Function.prototype.toString.
-spec method(term(), term(), non_neg_integer(), atom(), {module(), non_neg_integer(), non_neg_integer()}) -> term().
method(Fun, Key, Length, Kind, Source) when Kind =:= normal; Kind =:= sloppy ->
    %% The source goes into the record that the function is made with, so that
    %% its prototype stays lazy (buoy_heap:function/5).
    buoy_ref:named_fn(Fun, function_name(Key, <<>>), Length, {Kind, Source});
method(Fun, Key, Length, Kind, Source) ->
    F = method(Fun, Key, Length, Kind),
    buoy_heap:set_slots(F, (buoy_heap:slots(F))#{source => Source}),
    F.

prefix(get) -> <<"get ">>;
prefix(set) -> <<"set ">>;
prefix(_) -> <<>>.

%% SetFunctionName: the name of a function from a property key.
-spec function_name(term(), binary()) -> buoy_ref_string:js_string().
function_name(K, Prefix) when ?IS_STRING(K) -> buoy_ref_string:concat(Prefix, K);
function_name(K, Prefix) when is_integer(K) -> buoy_ref_string:concat(Prefix, integer_to_binary(K));
function_name({'$sym', _, undefined}, Prefix) -> Prefix;
function_name({'$sym', _, D}, Prefix) -> buoy_ref_string:concat([Prefix, <<"[">>, D, <<"]">>]);
function_name({'#', _, Name}, Prefix) -> buoy_ref_string:concat([Prefix, <<"#">>, Name]);
function_name(K, Prefix) -> buoy_ref_string:concat(Prefix, buoy_ref:to_string(K)).

%% A method or an accessor of a class on Home: DefinePropertyOrThrow, which
%% fails on a property that is not configurable, such as the prototype of the
%% class. Slot is method, get, or set; an accessor keeps the other half.
-spec define_method(term(), term(), term(), method | get | set) -> term().
define_method(Home, K, F, Slot) ->
    Existing = buoy_heap:get_own(Home, K),
    case Existing of
        {data, _, Bits} when Bits band 4 =:= 0 -> cannot_redefine(K);
        {accessor, _, _, Bits} when Bits band 4 =:= 0 -> cannot_redefine(K);
        _ -> ok
    end,
    Descriptor = case {Slot, Existing} of
        {method, _} -> #{value => F, writable => true};
        {get, {accessor, _, S, _}} -> #{get => F, set => S};
        {get, _} -> #{get => F, set => undefined};
        {set, {accessor, G, _, _}} -> #{get => G, set => F};
        {set, _} -> #{get => undefined, set => F}
    end,
    buoy_heap:define(Home, K, Descriptor#{enumerable => false, configurable => true}).

-spec cannot_redefine(term()) -> no_return().
cannot_redefine(K) ->
    buoy_ref:type_error(buoy_ref_string:concat([<<"Cannot redefine property: ">>, function_name(K, <<>>)])).

%% A public class field: CreateDataPropertyOrThrow.
-spec define_field(term(), term(), term()) -> term().
define_field(O, K, V) ->
    case buoy_heap:get_own(O, K) of
        {data, _, Bits} when Bits band 4 =:= 0 -> cannot_define(K);
        {accessor, _, _, Bits} when Bits band 4 =:= 0 -> cannot_define(K);
        none -> buoy_heap:is_extensible(O) orelse cannot_define(K);
        _ -> ok
    end,
    buoy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true}),
    V.

-spec cannot_define(term()) -> no_return().
cannot_define(K) ->
    buoy_ref:type_error(buoy_ref_string:concat([<<"Cannot define property ">>, function_name(K, <<>>), <<", object is not extensible">>])).

%%% Constructors

%% The default constructor of a derived class C: the parent constructs this.
-spec super_construct(term(), list(), term()) -> term().
super_construct(C, Args, NewTarget) ->
    construct_parent(buoy_heap:prototype_of(C), Args, NewTarget).

%% super(...args), with Parent the prototype of the class, read before the
%% arguments.
-spec construct_parent(term(), list(), term()) -> term().
construct_parent(Parent, Args, NewTarget) ->
    is_constructor(Parent) orelse buoy_ref:type_error(<<"Super constructor ", (describe(Parent))/binary, " of anonymous class is not a constructor">>),
    buoy_heap:construct(Parent, Args, NewTarget).

describe(V) ->
    case buoy_ref:describe(V) of
        B when is_binary(B) -> B;
        _ -> <<"value">>
    end.

%% The this of a derived constructor, held in a cell until super() binds it.
-spec this_of({'$c', pos_integer()}) -> term().
this_of(Cell) ->
    case buoy_heap:cell_get(Cell) of
        ?UNINITIALIZED -> buoy_heap:throw_error('ReferenceError', <<"Must call super constructor in derived class before accessing 'this' or returning from derived constructor">>);
        This -> This
    end.

-spec bind_this({'$c', pos_integer()}, term()) -> term().
bind_this(Cell, This) ->
    case buoy_heap:cell_get(Cell) of
        ?UNINITIALIZED -> buoy_heap:cell_set(Cell, This), This;
        _ -> buoy_heap:throw_error('ReferenceError', <<"Super constructor may only be called once">>)
    end.

%% The value of a binding that code may read before its declaration ran: a
%% ReferenceError until then (the temporal dead zone).
-spec initialized(term(), buoy_ref_string:js_string()) -> term().
initialized(?UNINITIALIZED, Name) ->
    buoy_heap:throw_error('ReferenceError', buoy_ref_string:concat([<<"Cannot access '">>, Name, <<"' before initialization">>]));
initialized(V, _Name) -> V.

%% An assignment to a module variable: a ReferenceError while its
%% declaration has not run in this realm.
-spec set_module(term(), term(), buoy_ref_string:js_string()) -> term().
set_module(Key, V, Name) ->
    case erlang:get(Key) of
        '$tdz' -> initialized(?UNINITIALIZED, Name);
        _ -> erlang:put(Key, {v, V}), V
    end.

%% The result of a base constructor that returns V: V when it is an object.
-spec base_return(term(), term()) -> term().
base_return(_This, V) when ?IS_OBJECT(V) -> V;
base_return(This, _V) -> This.

%% The result of a derived constructor that returns V.
%% The errors are values here, which constructed/1 throws in the caller's realm.
-spec derived_return({'$c', pos_integer()}, term()) -> term().
derived_return(_Cell, V) when ?IS_OBJECT(V) -> V;
derived_return(Cell, undefined) ->
    case buoy_heap:cell_get(Cell) of
        ?UNINITIALIZED -> {?CONSTRUCT_ERROR, 'ReferenceError', <<"Must call super constructor in derived class before accessing 'this' or returning from derived constructor">>};
        This -> This
    end;
derived_return(_Cell, _V) -> {?CONSTRUCT_ERROR, 'TypeError', <<"Derived constructors may only return object or undefined">>}.

%% The [[Construct]] of a function that reads new.target: Body takes it as a
%% third argument.
-spec new_target_construct(fun((term(), list(), term()) -> term()), term(), list()) -> term().
new_target_construct(Body, NewTarget, Args) ->
    This = buoy_ref:new_this(NewTarget),
    case Body(This, Args, NewTarget) of
        R when ?IS_OBJECT(R) -> R;
        _ -> This
    end.

%%% super.k

%% super.k: Base is the prototype of the home object, read when the reference
%% was made, and this is the receiver.
-spec super_get(term(), term(), term()) -> term().
super_get(null, K, _This) ->
    buoy_ref:type_error(<<"Cannot read properties of null (reading '", (key_text(buoy_ref:to_property_key(K)))/binary, "')">>);
super_get(Base, K, This) -> lookup(Base, buoy_ref:to_property_key(K), This).

lookup(null, _K, _Receiver) ->
    undefined;
lookup(O, K, Receiver) ->
    case buoy_heap:get_own(O, K) of
        {data, V, _} -> V;
        {accessor, undefined, _, _} -> undefined;
        {accessor, G, _, _} -> buoy_ref:call(G, Receiver, []);
        none -> lookup(buoy_heap:prototype_of(O), K, Receiver)
    end.

%% super.k = V: [[Set]] on Base with this as receiver. Strict code throws
%% when [[Set]] returns false, and sloppy code ignores it.
-spec super_set(term(), term(), term(), term()) -> term().
super_set(null, K, _V, _This) ->
    null_super_base(K);
super_set(Base, K, V, This) ->
    buoy_heap:set(Base, K, V, This) orelse buoy_heap:set_failed(This, K),
    V.

-spec sloppy_super_set(term(), term(), term(), term()) -> term().
sloppy_super_set(null, K, _V, _This) ->
    null_super_base(K);
sloppy_super_set(Base, K, V, This) ->
    _ = buoy_heap:set(Base, K, V, This),
    V.

-spec null_super_base(term()) -> no_return().
null_super_base(K) ->
    buoy_ref:type_error(<<"Cannot set properties of null (setting '", (key_text(K))/binary, "')">>).

key_text(K) ->
    case function_name(K, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<"key">>
    end.

%%% Private names

-spec private_name(binary()) -> {'#', pos_integer(), binary()}.
private_name(Name) -> {'#', erlang:unique_integer([positive]), Name}.

%% The private names of a class that declares many, in a tuple.
-spec private_names([binary()]) -> tuple().
private_names(Names) -> list_to_tuple([private_name(Name) || Name <- Names]).

%% o.#x
-spec private_get(term(), tuple()) -> term().
private_get(O, P) ->
    case find(O, P) of
        {ok, {'$method', F}} -> F;
        {ok, {'$accessor', undefined, _}} -> buoy_ref:type_error(<<"'", (key_text(P))/binary, "' was defined without a getter">>);
        {ok, {'$accessor', G, _}} -> buoy_ref:call(G, O, []);
        {ok, V} -> V;
        error -> missing(O, P, <<"read">>)
    end.

%% o.#x = v
-spec private_set(term(), tuple(), term()) -> term().
private_set(O, P, V) ->
    case find(O, P) of
        {ok, {'$method', _}} -> buoy_ref:type_error(<<"Private method '", (key_text(P))/binary, "' is not writable">>);
        {ok, {'$accessor', _, undefined}} -> buoy_ref:type_error(<<"'", (key_text(P))/binary, "' was defined without a setter">>);
        {ok, {'$accessor', _, S}} -> buoy_ref:call(S, O, [V]);
        {ok, _} -> buoy_heap:private_put(O, P, V);
        error -> missing(O, P, <<"write">>)
    end,
    V.

%% #x in o
-spec private_in(tuple(), term()) -> boolean().
private_in(P, O) when ?IS_OBJECT(O) -> find(O, P) =/= error;
private_in(P, O) -> buoy_ref:type_error(<<"Cannot use 'in' operator to search for '", (key_text(P))/binary, "' in ", (describe(O))/binary>>).

find(O, P) when ?IS_OBJECT(O) -> buoy_heap:private_find(O, P);
find(_O, _P) -> error.

-spec missing(term(), tuple(), binary()) -> no_return().
missing(O, P, What) when ?IS_OBJECT(O) ->
    buoy_ref:type_error(<<"Cannot ", What/binary, " private member ", (key_text(P))/binary, " from an object whose class did not declare it">>);
missing(O, P, What) ->
    buoy_ref:type_error(<<"Cannot ", What/binary, " private member ", (key_text(P))/binary, " from ", (describe(O))/binary>>).

%% PrivateFieldAdd: a TypeError when the object has the element already.
-spec private_add(term(), tuple(), term()) -> term().
private_add(O, P, V) ->
    find(O, P) =:= error orelse
        buoy_ref:type_error(<<"Cannot initialize ", (key_text(P))/binary, " twice on the same object">>),
    buoy_heap:private_put(O, P, V),
    V.

%% PrivateMethodOrAccessorAdd for each method: {P, method | get | set, F}. A
%% getter and a setter of one name make one accessor.
-spec add_private_methods(term(), [{tuple(), atom(), term()}]) -> ok.
add_private_methods(O, Methods) ->
    Elements = lists:foldl(fun merge/2, [], Methods),
    [begin
         find(O, P) =:= error orelse
             buoy_ref:type_error(<<"Cannot initialize private methods of class ", (key_text(P))/binary, " twice on the same object">>),
         buoy_heap:private_put(O, P, Slot)
     end || {P, Slot} <- lists:reverse(Elements)],
    ok.

merge({P, method, F}, Acc) -> [{P, {'$method', F}} | Acc];
merge({P, get, G}, Acc) ->
    case lists:keytake(P, 1, Acc) of
        {value, {P, {'$accessor', _, S}}, Rest} -> [{P, {'$accessor', G, S}} | Rest];
        _ -> [{P, {'$accessor', G, undefined}} | Acc]
    end;
merge({P, set, S}, Acc) ->
    case lists:keytake(P, 1, Acc) of
        {value, {P, {'$accessor', G, _}}, Rest} -> [{P, {'$accessor', G, S}} | Rest];
        _ -> [{P, {'$accessor', undefined, S}} | Acc]
    end.
