%% The value core: the JavaScript semantics that compiled code calls
%% (contract sections 3 to 7 and 16).
-module(bouy_rt).

-export([arg/2, rest/2, call/2, call_method/3, mutate/3]).
-export([add/2, sub/2, mul/2, divide/2, remainder/2, power/2, negate/1, to_number/1]).
-export([bit_and/2, bit_or/2, bit_xor/2, bit_not/1, shift_left/2, shift_right/2, shift_right_unsigned/2]).
-export([strict_eq/2, loose_eq/2, lt/2, le/2, gt/2, ge/2]).
-export([truthy/1, type_of/1, instance_of/2, has/2]).
-export([to_string/1, concat/1]).
-export([get/2, set/3, delete/2]).
-export([object/1, array/1, object_rest/2, array_rest/2]).
-export([to_list/1, keys/1, caught/2]).
-export([env/1, argv/0, structured_clone/1]).
%% Conversions that the other runtime modules share.
-export([to_key/1, to_index/1, to_primitive/1, to_integer/1, to_int32/1, to_uint32/1]).
-export([relative_index/3, clamp/3, collection_key/1, same_value_zero/2, signed_infinity/1]).
-export([member_function/3, member/3, prototype_call/3, global_name/1]).
-export([describe/1, prefix/2, no_method/2]).

-type value() :: term().
-type js_number() :: number() | 'NaN' | 'Infinity' | '-Infinity'.
-type args() :: [value()].
-export_type([value/0, js_number/0, args/0]).

-define(IS_NUMBER(X), (is_number(X) orelse X =:= 'NaN' orelse X =:= 'Infinity' orelse X =:= '-Infinity')).
-define(IS_NULLISH(X), (X =:= undefined orelse X =:= null)).
-define(IS_PRIMITIVE(X), (?IS_NUMBER(X) orelse is_binary(X) orelse is_boolean(X) orelse ?IS_NULLISH(X))).

%% Namespace modules that are constructors, so `typeof` says "function".
-define(CONSTRUCTORS, [bouy_array, bouy_date, bouy_error, bouy_map, bouy_number, bouy_object, bouy_set, bouy_string, bouy_task]).
%% The methods of Object.prototype, which every value inherits.
-define(OBJECT_METHODS, [<<"hasOwnProperty">>, <<"isPrototypeOf">>, <<"propertyIsEnumerable">>, <<"toLocaleString">>, <<"toString">>, <<"valueOf">>]).
-define(FUNCTION_METHODS, [<<"apply">>, <<"bind">>, <<"call">>, <<"toString">>]).
-define(BOOLEAN_METHODS, [<<"toString">>, <<"valueOf">>]).

%%% Calling convention

-spec arg(pos_integer(), args()) -> value().
arg(1, [Value | _]) -> Value;
arg(N, [_ | Rest]) when N > 1 -> arg(N - 1, Rest);
arg(_, _) -> undefined.

-spec rest(pos_integer(), args()) -> args().
rest(1, Args) -> Args;
rest(N, [_ | Rest]) when N > 1 -> rest(N - 1, Rest);
rest(_, []) -> [].

-spec call(value(), args()) -> value().
call(F, Args) when is_function(F, 1) -> F(Args);
%% A function with properties, such as the provider of createOpenAI.
call(#{'$call' := F}, Args) -> F(Args);
call({'$namespace', Module} = F, Args) ->
    case is_exported(Module, '$call') of
        true -> Module:'$call'(Args);
        false -> type_error(<<(describe(F))/binary, " is not a function">>)
    end;
call({'$method', bouy_object, Name}, Args) ->
    %% A built-in method read as a property has no receiver: `this` is undefined.
    object_method(undefined, Name, Args);
call({'$method', Module, Name}, _Args) ->
    type_error(<<(owner_name(Module))/binary, ".prototype.", Name/binary, " called on null or undefined">>);
call(F, _Args) ->
    type_error(<<(describe(F))/binary, " is not a function">>).

is_exported(Module, Function) ->
    code:ensure_loaded(Module) =:= {module, Module} andalso erlang:function_exported(Module, Function, 1).

%% `r[name](args)`. A key that is not a string, such as the index of
%% `handlers[0](x)`, names a property like any other key.
-spec call_method(value(), value(), args()) -> value().
call_method(R, Name, Args) when not is_binary(Name) -> call_method(R, to_key(Name), Args);
call_method(R, Name, Args) when is_list(R) ->
    case to_index(Name) of
        none -> bouy_array:call(Name, R, Args);
        _Index -> call_value(bouy_array:get(R, Name), R, Name, Args)
    end;
call_method(R, Name, Args) when is_binary(R) -> bouy_string:call(Name, R, Args);
call_method(R, Name, Args) when ?IS_NUMBER(R) -> bouy_number:call(Name, R, Args);
call_method({'$map', _} = R, Name, Args) -> bouy_map:call(Name, R, Args);
call_method({'$set', _} = R, Name, Args) -> bouy_set:call(Name, R, Args);
call_method({'$ref', _} = R, Name, Args) -> bouy_actor:call(R, Name, Args);
call_method({'$cast', _} = R, Name, Args) -> bouy_actor:cast(R, Name, Args);
call_method({'$date', _} = R, Name, Args) -> bouy_date:call(Name, R, Args);
call_method({'$iterator', _, _} = R, Name, Args) -> bouy_iterator:call(Name, R, Args);
call_method({'$effect', _} = R, Name, Args) -> bouy_effect:call(Name, R, Args);
call_method({'$namespace', Module} = R, Name, Args) -> namespace_call(R, Module:'$member'(Name), Name, Args);
call_method({'$method', _, _} = R, Name, Args) -> method_call(R, Name, Args);
%% Bouy errors carry their stack from construction, so there is nothing to capture.
call_method({'$class', _, _}, <<"captureStackTrace">>, _Args) -> undefined;
call_method(#{'$error' := _} = R, Name, Args) -> bouy_error:call(Name, R, Args);
call_method(R, Name, Args) when is_map(R) -> object_call(R, Name, Args);
call_method(R, Name, Args) when is_function(R, 1) -> function_call(R, Name, Args);
call_method(R, <<"toString">>, _Args) when is_boolean(R) -> to_string(R);
call_method(R, <<"valueOf">>, _Args) when is_boolean(R) -> R;
call_method(R, Name, _Args) when ?IS_NULLISH(R) -> read_error(R, Name);
call_method(R, Name, Args) -> prototype_call(R, Name, Args).

namespace_call(R, undefined, Name, _Args) -> no_method(R, Name);
namespace_call(_R, F, _Name, Args) -> call(F, Args).

object_call(R, Name, Args) ->
    case R of
        #{Name := F} -> call_value(F, R, Name, Args);
        _ -> prototype_call(R, Name, Args)
    end.

%% Calls F, the property Name of R, with R as `this` for a built-in method.
call_value(F, _R, _Name, Args) when is_function(F, 1) -> F(Args);
call_value({'$method', _, _} = F, R, _Name, Args) -> invoke(F, R, Args);
call_value({'$namespace', _} = F, _R, _Name, Args) -> call(F, Args);
call_value(_F, R, Name, _Args) -> no_method(R, Name).

%% A method of Object.prototype on any receiver, which every value inherits.
-spec prototype_call(value(), binary(), args()) -> value().
prototype_call(R, Name, Args) ->
    case lists:member(Name, ?OBJECT_METHODS) of
        true -> object_method(R, Name, Args);
        false -> no_method(R, Name)
    end.

object_method(R, <<"toString">>, _Args) -> <<"[object ", (tag(R))/binary, "]">>;
object_method(R, _Name, _Args) when ?IS_NULLISH(R) ->
    type_error(<<"Cannot convert undefined or null to object">>);
object_method(R, <<"hasOwnProperty">>, Args) -> bouy_object:'hasOwn'([R, arg(1, Args)]);
object_method(R, <<"propertyIsEnumerable">>, Args) -> lists:keymember(to_key(arg(1, Args)), 1, bouy_object:own_entries(R));
object_method(_R, <<"isPrototypeOf">>, _Args) -> false;
object_method(R, <<"toLocaleString">>, _Args) -> call_method(R, <<"toString">>, []);
object_method(R, <<"valueOf">>, _Args) -> R.

%% The tag of Object.prototype.toString.
tag(undefined) -> <<"Undefined">>;
tag(null) -> <<"Null">>;
tag(V) when is_list(V) -> <<"Array">>;
tag(V) when is_binary(V) -> <<"String">>;
tag(V) when ?IS_NUMBER(V) -> <<"Number">>;
tag(V) when is_boolean(V) -> <<"Boolean">>;
tag(#{'$error' := _}) -> <<"Error">>;
tag({'$map', _}) -> <<"Map">>;
tag({'$set', _}) -> <<"Set">>;
tag({'$date', _}) -> <<"Date">>;
tag({'$iterator', Kind, _}) -> Kind;
tag(V) ->
    case type_of(V) of
        <<"function">> -> <<"Function">>;
        _ -> <<"Object">>
    end.

%% `f.call`, `f.apply`, and `f.bind` of a built-in method read as a property.
method_call(M, <<"call">>, Args) -> invoke(M, arg(1, Args), rest(2, Args));
method_call(M, <<"apply">>, Args) -> invoke(M, arg(1, Args), apply_arguments(arg(2, Args)));
method_call(M, <<"bind">>, Args) ->
    This = arg(1, Args),
    Bound = rest(2, Args),
    fun(More) -> invoke(M, This, Bound ++ More) end;
method_call(M, <<"toString">>, _Args) -> to_string(M);
method_call(M, Name, Args) -> prototype_call(M, Name, Args).

%% Runs a built-in method with `This` as its receiver. Object.prototype and
%% Error.prototype methods work on any receiver; the others dispatch on it.
invoke({'$method', bouy_object, Name}, This, Args) -> object_method(This, Name, Args);
invoke({'$method', bouy_error, <<"toString">>}, This, _Args) when is_map(This) -> bouy_error:to_string(This);
invoke({'$method', _, Name}, This, Args) -> call_method(This, Name, Args).

function_call(F, <<"call">>, Args) -> F(rest(2, Args));
function_call(F, <<"apply">>, Args) -> F(apply_arguments(arg(2, Args)));
function_call(F, <<"bind">>, Args) -> Bound = rest(2, Args), fun(More) -> F(Bound ++ More) end;
function_call(F, <<"toString">>, _Args) -> to_string(F);
function_call(F, Name, Args) -> prototype_call(F, Name, Args).

apply_arguments(Args) when ?IS_NULLISH(Args) -> [];
apply_arguments(Args) -> to_list(Args).

-spec mutate(value(), binary(), args()) -> {value(), value()}.
mutate(R, Name, Args) when is_list(R) -> bouy_array:mutate(Name, R, Args);
mutate({'$map', _} = R, Name, Args) -> bouy_map:mutate(Name, R, Args);
mutate({'$set', _} = R, Name, Args) -> bouy_set:mutate(Name, R, Args);
mutate({'$iterator', _, _} = R, Name, Args) -> bouy_iterator:mutate(Name, R, Args);
mutate(R, Name, Args) -> {call_method(R, Name, Args), R}.

%%% Arithmetic

-spec add(value(), value()) -> value().
add(A, B) when is_integer(A), is_integer(B) -> A + B;
add(A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
add(A, B) when ?IS_NUMBER(A), ?IS_NUMBER(B) -> arith(add, A, B);
add(A, B) ->
    PA = to_primitive(A),
    PB = to_primitive(B),
    case is_binary(PA) orelse is_binary(PB) of
        true -> <<(to_string(PA))/binary, (to_string(PB))/binary>>;
        false -> arith(add, to_number(PA), to_number(PB))
    end.

-spec sub(value(), value()) -> js_number().
sub(A, B) when is_integer(A), is_integer(B) -> A - B;
sub(A, B) -> arith(sub, to_number(A), to_number(B)).

-spec mul(value(), value()) -> js_number().
mul(A, B) when is_integer(A), is_integer(B) -> A * B;
mul(A, B) -> arith(mul, to_number(A), to_number(B)).

-spec divide(value(), value()) -> js_number().
divide(A, B) when is_integer(A), is_integer(B), B =/= 0, A rem B =:= 0 -> A div B;
divide(A, B) -> quotient(to_number(A), to_number(B)).

%% JavaScript `%`: the result takes the sign of the dividend.
-spec remainder(value(), value()) -> js_number().
remainder(A, B) when is_integer(A), is_integer(B), B =/= 0 -> A rem B;
remainder(A, B) -> modulo(to_number(A), to_number(B)).

-spec power(value(), value()) -> js_number().
power(A, B) -> pow(to_number(A), to_number(B)).

-spec negate(value()) -> js_number().
negate(A) when is_number(A) -> -A;
negate('Infinity') -> '-Infinity';
negate('-Infinity') -> 'Infinity';
negate('NaN') -> 'NaN';
negate(A) -> negate(to_number(A)).

-spec to_number(value()) -> js_number().
to_number(N) when ?IS_NUMBER(N) -> N;
to_number(B) when is_binary(B) -> bouy_number:from_string(B);
to_number(true) -> 1;
to_number(false) -> 0;
to_number(null) -> 0;
to_number(undefined) -> 'NaN';
to_number({'$date', Time}) -> Time;
to_number(V) when is_list(V); is_map(V) -> to_number(to_primitive(V));
to_number(_) -> 'NaN'.

%% Addition, subtraction, and multiplication with IEEE 754 results where
%% Erlang raises: overflow becomes an infinity and NaN propagates.
arith(add, A, B) when is_integer(A), is_integer(B) -> A + B;
arith(sub, A, B) when is_integer(A), is_integer(B) -> A - B;
arith(mul, A, B) when is_integer(A), is_integer(B) -> A * B;
arith(Op, A, B) when is_number(A), is_number(B) ->
    try float_op(Op, A, B) of
        Result -> Result
    catch
        error:badarith -> overflowed(Op, extend(A), extend(B))
    end;
arith(Op, A, B) ->
    infinite(Op, A, B).

float_op(add, A, B) -> A + B;
float_op(sub, A, B) -> A - B;
float_op(mul, A, B) -> A * B.

overflowed(Op, A, B) when is_number(A), is_number(B) ->
    case Op of
        add -> signed_infinity(A / 2 + B / 2);
        sub -> signed_infinity(A / 2 - B / 2);
        mul -> signed_infinity(sign_bit(A) * sign_bit(B))
    end;
overflowed(Op, A, B) ->
    infinite(Op, A, B).

infinite(_, 'NaN', _) -> 'NaN';
infinite(_, _, 'NaN') -> 'NaN';
infinite(sub, A, B) -> infinite(add, A, negate(B));
infinite(add, A, B) when is_atom(A), is_atom(B), A =/= B -> 'NaN';
infinite(add, A, _) when is_atom(A) -> A;
infinite(add, _, B) -> B;
infinite(mul, A, B) ->
    case sign(A) * sign(B) of
        0 -> 'NaN';
        S -> signed_infinity(S)
    end.

quotient('NaN', _) -> 'NaN';
quotient(_, 'NaN') -> 'NaN';
quotient(A, B) when is_atom(A), is_atom(B) -> 'NaN';
quotient(A, B) when is_atom(A) -> signed_infinity(sign_bit(A) * sign_bit(B));
quotient(A, B) when is_atom(B) -> signed_zero(sign_bit(A) * sign_bit(B));
quotient(A, B) when B == 0, A == 0 -> 'NaN';
quotient(A, B) when B == 0 -> signed_infinity(sign_bit(A) * sign_bit(B));
quotient(A, B) when is_integer(A), is_integer(B), A rem B =:= 0 -> A div B;
quotient(A, B) ->
    try A / B of
        Result -> Result
    catch
        error:badarith -> quotient_overflow(extend(A), extend(B))
    end.

quotient_overflow(A, B) when is_number(A), is_number(B) -> signed_infinity(sign_bit(A) * sign_bit(B));
quotient_overflow(A, B) -> quotient(A, B).

modulo('NaN', _) -> 'NaN';
modulo(_, 'NaN') -> 'NaN';
modulo(A, _) when is_atom(A) -> 'NaN';
modulo(A, B) when is_atom(B) -> A;
modulo(_, B) when B == 0 -> 'NaN';
modulo(A, B) when is_integer(A), is_integer(B) -> A rem B;
modulo(A, B) ->
    case {extend(A), extend(B)} of
        {FA, FB} when is_number(FA), is_number(FB) -> math:fmod(float(FA), float(FB));
        {FA, FB} -> modulo(FA, FB)
    end.

pow(_, B) when B == 0 -> 1;
pow('NaN', _) -> 'NaN';
pow(_, 'NaN') -> 'NaN';
pow(A, B) when is_integer(A), is_integer(B), B > 0 -> integer_pow(A, B);
pow(A, 'Infinity') -> infinite_exponent(compare_abs_one(A), 'Infinity', 0);
pow(A, '-Infinity') -> infinite_exponent(compare_abs_one(A), 0, 'Infinity');
pow('Infinity', B) when B > 0 -> 'Infinity';
pow('Infinity', _) -> 0.0;
pow('-Infinity', B) -> odd_power(B, pow('Infinity', B));
pow(A, B) when A == 0, B > 0 -> odd_power_of_zero(A, B, 0.0);
pow(A, B) when A == 0 -> odd_power_of_zero(A, B, 'Infinity');
pow(A, B) when A < 0, B /= trunc(B) -> 'NaN';
pow(A, B) ->
    try float_pow(float(A), float(B)) of
        Result -> Result
    catch
        error:_ -> odd_power(B, pow_overflow(A, B))
    end.

%% V8 squares for an exponent of 2 and takes the square root for 0.5;
%% other exponents go to the C library's pow, as in V8.
float_pow(A, 2.0) -> A * A;
float_pow(A, 0.5) -> math:sqrt(A);
float_pow(A, B) -> math:pow(A, B).

pow_overflow(A, B) when abs(A) > 1, B > 0; abs(A) < 1, B < 0 -> 'Infinity';
pow_overflow(_, _) -> 0.0.

infinite_exponent(gt, Above, _) -> Above;
infinite_exponent(eq, _, _) -> 'NaN';
infinite_exponent(lt, _, Below) -> Below.

compare_abs_one(A) when is_atom(A) -> gt;
compare_abs_one(A) when abs(A) > 1 -> gt;
compare_abs_one(A) when abs(A) == 1 -> eq;
compare_abs_one(_) -> lt.

%% `(-x) ** b` for an odd integer `b` flips the sign of `x ** b`.
odd_power(B, Result) when is_number(B), B == trunc(B), trunc(B) rem 2 =/= 0 -> negate(Result);
odd_power(_, Result) -> Result.

odd_power_of_zero(A, B, Result) ->
    case sign_bit(A) of
        -1 -> odd_power(B, Result);
        1 -> Result
    end.

integer_pow(_, 0) -> 1;
integer_pow(A, 1) -> A;
integer_pow(A, B) when B rem 2 =:= 0 -> integer_pow(A * A, B div 2);
integer_pow(A, B) -> A * integer_pow(A * A, B div 2).

%% An integer too large for a double becomes an infinity, as in JavaScript.
extend(I) when is_integer(I) ->
    try float(I) of
        _ -> I
    catch
        error:badarg -> signed_infinity(I)
    end;
extend(N) ->
    N.

-spec signed_infinity(number()) -> 'Infinity' | '-Infinity'.
signed_infinity(N) when N < 0 -> '-Infinity';
signed_infinity(_) -> 'Infinity'.

signed_zero(-1) -> -0.0;
signed_zero(_) -> 0.0.

sign('Infinity') -> 1;
sign('-Infinity') -> -1;
sign(N) when N > 0 -> 1;
sign(N) when N < 0 -> -1;
sign(_) -> 0.

%% The IEEE sign bit: -0.0 is negative.
sign_bit('-Infinity') -> -1;
sign_bit('Infinity') -> 1;
sign_bit(I) when is_integer(I), I < 0 -> -1;
sign_bit(I) when is_integer(I) -> 1;
sign_bit(F) ->
    case <<F/float>> of
        <<1:1, _:63>> -> -1;
        _ -> 1
    end.

%%% Bitwise operators on 32-bit integers

-spec bit_and(value(), value()) -> integer().
bit_and(A, B) -> to_int32(A) band to_int32(B).

-spec bit_or(value(), value()) -> integer().
bit_or(A, B) -> to_int32(A) bor to_int32(B).

-spec bit_xor(value(), value()) -> integer().
bit_xor(A, B) -> to_int32(A) bxor to_int32(B).

-spec bit_not(value()) -> integer().
bit_not(A) -> bnot to_int32(A).

-spec shift_left(value(), value()) -> integer().
shift_left(A, B) -> wrap_int32(to_int32(A) bsl (to_uint32(B) band 31)).

-spec shift_right(value(), value()) -> integer().
shift_right(A, B) -> to_int32(A) bsr (to_uint32(B) band 31).

-spec shift_right_unsigned(value(), value()) -> non_neg_integer().
shift_right_unsigned(A, B) -> to_uint32(A) bsr (to_uint32(B) band 31).

-spec to_int32(value()) -> integer().
to_int32(V) -> wrap_int32(to_uint32(V)).

-spec to_uint32(value()) -> non_neg_integer().
to_uint32(V) ->
    case to_number(V) of
        I when is_integer(I) -> I band 16#FFFFFFFF;
        F when is_float(F) -> trunc(F) band 16#FFFFFFFF;
        _ -> 0
    end.

wrap_int32(I) ->
    case I band 16#FFFFFFFF of
        U when U >= 16#80000000 -> U - 16#100000000;
        U -> U
    end.

%%% Comparison

-spec strict_eq(value(), value()) -> boolean().
strict_eq(A, B) when is_integer(A), is_integer(B) -> A =:= B;
strict_eq(A, B) when is_binary(A), is_binary(B) -> A =:= B;
strict_eq(A, B) when is_number(A), is_number(B) -> A == B;
strict_eq('NaN', _) -> false;
strict_eq(A, B) when is_atom(A); is_atom(B) -> A =:= B;
strict_eq(A, B) when is_list(A), is_list(B) -> same_items(A, B);
strict_eq(A, B) when is_map(A), is_map(B) -> map_size(A) =:= map_size(B) andalso same_fields(maps:iterator(A), B);
strict_eq({'$map', _} = A, {'$map', _} = B) -> same_items(to_list(A), to_list(B));
strict_eq({'$set', _} = A, {'$set', _} = B) -> same_items(to_list(A), to_list(B));
strict_eq(A, B) -> A =:= B.

same_items([A | As], [B | Bs]) -> strict_eq(A, B) andalso same_items(As, Bs);
same_items([], []) -> true;
same_items(_, _) -> false.

same_fields(Iterator, B) ->
    case maps:next(Iterator) of
        none ->
            true;
        {Key, Value, Next} ->
            case B of
                #{Key := Other} -> strict_eq(Value, Other) andalso same_fields(Next, B);
                _ -> false
            end
    end.

-spec loose_eq(value(), value()) -> boolean().
loose_eq(A, B) when is_number(A), is_number(B) -> A == B;
loose_eq(A, B) when is_binary(A), is_binary(B) -> A =:= B;
loose_eq(A, B) when ?IS_NULLISH(A) -> ?IS_NULLISH(B);
loose_eq(_, B) when ?IS_NULLISH(B) -> false;
loose_eq(A, B) when is_boolean(A) -> loose_eq(to_number(A), B);
loose_eq(A, B) when is_boolean(B) -> loose_eq(A, to_number(B));
loose_eq(A, B) when ?IS_NUMBER(A), ?IS_NUMBER(B) -> strict_eq(A, B);
loose_eq(A, B) when ?IS_NUMBER(A), is_binary(B) -> strict_eq(A, to_number(B));
loose_eq(A, B) when is_binary(A), ?IS_NUMBER(B) -> strict_eq(to_number(A), B);
loose_eq(A, B) when ?IS_PRIMITIVE(A), not ?IS_PRIMITIVE(B) -> loose_eq(A, to_primitive(B));
loose_eq(A, B) when ?IS_PRIMITIVE(B), not ?IS_PRIMITIVE(A) -> loose_eq(to_primitive(A), B);
loose_eq(A, B) -> strict_eq(A, B).

-spec lt(value(), value()) -> boolean().
lt(A, B) when is_number(A), is_number(B) -> A < B;
lt(A, B) when is_binary(A), is_binary(B) -> A < B;
lt(A, B) -> compare(A, B) =:= lt.

-spec le(value(), value()) -> boolean().
le(A, B) when is_number(A), is_number(B) -> A =< B;
le(A, B) when is_binary(A), is_binary(B) -> A =< B;
le(A, B) -> lists:member(compare(A, B), [lt, eq]).

-spec gt(value(), value()) -> boolean().
gt(A, B) when is_number(A), is_number(B) -> A > B;
gt(A, B) when is_binary(A), is_binary(B) -> A > B;
gt(A, B) -> compare(A, B) =:= gt.

-spec ge(value(), value()) -> boolean().
ge(A, B) when is_number(A), is_number(B) -> A >= B;
ge(A, B) when is_binary(A), is_binary(B) -> A >= B;
ge(A, B) -> lists:member(compare(A, B), [gt, eq]).

%% `lt`, `eq`, `gt`, or `undefined` when a side is NaN. Strings compare by
%% code point, other values as numbers.
compare(A, B) ->
    case {number_hint(A), number_hint(B)} of
        {PA, PB} when is_binary(PA), is_binary(PB) -> order(PA, PB);
        {PA, PB} -> number_order(to_number(PA), to_number(PB))
    end.

number_order('NaN', _) -> undefined;
number_order(_, 'NaN') -> undefined;
number_order(Same, Same) -> eq;
number_order('-Infinity', _) -> lt;
number_order(_, '-Infinity') -> gt;
number_order('Infinity', _) -> gt;
number_order(_, 'Infinity') -> lt;
number_order(A, B) -> order(A, B).

order(A, B) when A < B -> lt;
order(A, B) when A > B -> gt;
order(_, _) -> eq.

%%% Tests

-spec truthy(value()) -> boolean().
truthy(true) -> true;
truthy(false) -> false;
truthy(undefined) -> false;
truthy(null) -> false;
truthy(0) -> false;
truthy(F) when is_float(F) -> F /= 0;
truthy('NaN') -> false;
truthy(<<>>) -> false;
truthy(_) -> true.

-spec type_of(value()) -> binary().
type_of(undefined) -> <<"undefined">>;
type_of(V) when is_boolean(V) -> <<"boolean">>;
type_of(V) when ?IS_NUMBER(V) -> <<"number">>;
type_of(V) when is_binary(V) -> <<"string">>;
type_of(V) when is_function(V) -> <<"function">>;
type_of(#{'$call' := _}) -> <<"function">>;
type_of({'$class', _, _}) -> <<"function">>;
type_of({'$method', _, _}) -> <<"function">>;
%% A namespace that can be called, such as `openai`, is a function too.
type_of({'$namespace', Module}) ->
    case lists:member(Module, ?CONSTRUCTORS) orelse is_exported(Module, '$call') of
        true -> <<"function">>;
        false -> <<"object">>
    end;
type_of(_) -> <<"object">>.

%% An error is an instance of the classes that built it, and of `Error`. A
%% global namespace such as `Map` or `Array` matches its own values.
-spec instance_of(value(), value()) -> boolean().
instance_of(V, {'$class', bouy_error, <<"Error">>}) -> is_error(V);
instance_of(#{'$error' := Classes}, {'$class', _, _} = Class) -> lists:member(Class, Classes);
instance_of(_, {'$class', _, _}) -> false;
instance_of(V, {'$namespace', Module}) -> is_instance(Module, V);
instance_of(_, C) when is_function(C) -> false;
instance_of(_, {'$method', _, _}) -> false;
instance_of(_, C) when ?IS_PRIMITIVE(C) -> type_error(<<"Right-hand side of 'instanceof' is not an object">>);
instance_of(_, _) -> type_error(<<"Right-hand side of 'instanceof' is not callable">>).

is_instance(bouy_array, V) -> is_list(V);
is_instance(bouy_map, V) -> is_tuple(V) andalso element(1, V) =:= '$map';
is_instance(bouy_set, V) -> is_tuple(V) andalso element(1, V) =:= '$set';
is_instance(bouy_date, V) -> is_tuple(V) andalso element(1, V) =:= '$date';
is_instance(bouy_error, V) -> is_error(V);
is_instance(bouy_object, V) -> not ?IS_PRIMITIVE(V);
is_instance(_, _) -> false.

is_error(#{'$error' := _}) -> true;
is_error(_) -> false.

%% `key in object`: own properties and the members every value inherits.
-spec has(value(), value()) -> boolean().
has(O, K) when is_map(O) -> property(O, to_key(K)) =/= undefined orelse maps:is_key(to_key(K), O);
has(O, K) when is_list(O) ->
    Key = to_key(K),
    Key =:= <<"length">> orelse index_in(Key, length(O)) orelse bouy_array:get([], Key) =/= undefined;
has(O, K) when ?IS_PRIMITIVE(O) ->
    type_error(<<"Cannot use 'in' operator to search for '", (to_key(K))/binary, "' in ", (to_string(O))/binary>>);
has(O, K) -> get(O, K) =/= undefined.

index_in(K, Length) ->
    case to_index(K) of
        I when is_integer(I) -> I < Length;
        none -> false
    end.

%%% Strings

-spec to_string(value()) -> binary().
to_string(B) when is_binary(B) -> B;
to_string(I) when is_integer(I) -> integer_to_binary(I);
to_string(true) -> <<"true">>;
to_string(false) -> <<"false">>;
to_string(null) -> <<"null">>;
to_string(undefined) -> <<"undefined">>;
to_string(N) when ?IS_NUMBER(N) -> bouy_number:to_string(N);
to_string(L) when is_list(L) -> bouy_array:join(L, <<",">>);
to_string(#{'$error' := _} = E) -> bouy_error:to_string(E);
to_string(M) when is_map(M) -> to_string(ordinary_primitive(M, [<<"toString">>, <<"valueOf">>]));
to_string({'$map', _}) -> <<"[object Map]">>;
to_string({'$set', _}) -> <<"[object Set]">>;
to_string({'$date', _} = D) -> bouy_date:to_string(D);
to_string({'$iterator', Kind, _}) -> <<"[object ", Kind/binary, "]">>;
to_string({'$class', _, Name}) -> <<"class ", Name/binary, " { [native code] }">>;
to_string({'$method', _, Name}) -> <<"function ", Name/binary, "() { [native code] }">>;
to_string(F) when is_function(F) -> <<"function ", (bouy_console:function_name(F))/binary, "() { [native code] }">>;
to_string(_) -> <<"[object Object]">>.

-spec concat([value()]) -> binary().
concat(Parts) ->
    iolist_to_binary([to_string(Part) || Part <- Parts]).

%% JavaScript ToPrimitive with the default hint: a plain object tries its
%% own `valueOf`, then its `toString`, and other objects become strings.
-spec to_primitive(value()) -> value().
to_primitive(V) when ?IS_PRIMITIVE(V) -> V;
to_primitive(#{'$error' := _} = E) -> bouy_error:to_string(E);
to_primitive(M) when is_map(M) -> ordinary_primitive(M, [<<"valueOf">>, <<"toString">>]);
to_primitive(V) -> to_string(V).

%% OrdinaryToPrimitive for a plain object. Only own methods can be
%% functions here; the inherited `valueOf` returns the object, and the
%% inherited `toString` gives "[object Object]".
ordinary_primitive(O, [Name | Rest]) ->
    case O of
        #{Name := F} when is_function(F, 1) ->
            case F([]) of
                Primitive when ?IS_PRIMITIVE(Primitive) -> Primitive;
                _ -> ordinary_primitive(O, Rest)
            end;
        #{Name := _} -> ordinary_primitive(O, Rest);
        _ when Name =:= <<"toString">> -> <<"[object Object]">>;
        _ -> ordinary_primitive(O, Rest)
    end;
ordinary_primitive(_O, []) ->
    type_error(<<"Cannot convert object to primitive value">>).

%% ToPrimitive with the number hint, as relational operators use it: a
%% Date becomes its time value.
number_hint({'$date', Time}) -> Time;
number_hint(V) -> to_primitive(V).

%%% Properties

-spec get(value(), value()) -> value().
get(O, K) when is_map(O), is_binary(K) -> property(O, K);
get(O, K) when is_map(O) -> property(O, to_key(K));
get(O, K) when is_list(O) -> bouy_array:get(O, K);
get(O, K) when is_binary(O) -> bouy_string:get(O, K);
get(O, K) when ?IS_NUMBER(O) -> bouy_number:get(O, K);
get(O, K) when is_boolean(O) -> member(boolean, K, ?BOOLEAN_METHODS);
get({'$map', _} = M, K) -> bouy_map:get(M, K);
get({'$set', _} = S, K) -> bouy_set:get(S, K);
get({'$date', _} = D, K) -> bouy_date:get(D, K);
get({'$iterator', _, _} = I, K) -> bouy_iterator:get(I, K);
get({'$namespace', Module}, K) -> Module:'$member'(to_key(K));
get({'$class', _, _} = C, K) -> class_member(C, to_key(K));
get({'$method', _, Name}, <<"name">>) -> Name;
get({'$method', _, _}, K) -> member(function, K, ?FUNCTION_METHODS);
get({'$prototype', Owner}, K) -> prototype_member(Owner, to_key(K));
get(F, <<"name">>) when is_function(F) -> bouy_console:function_name(F);
get(F, K) when is_function(F) -> member(function, K, ?FUNCTION_METHODS);
get(O, K) when ?IS_NULLISH(O) -> read_error(O, K);
get(_, _) -> undefined.

%% An own property of an object or an error, or a member it inherits.
property(O, K) ->
    case O of
        #{K := V} -> V;
        #{'$error' := _} -> error_member(O, K);
        _ -> object_member(K)
    end.

error_member(E, <<"constructor">>) -> bouy_error:class(E);
error_member(_E, <<"toString">>) -> {'$method', bouy_error, <<"toString">>};
error_member(_E, K) -> object_member(K).

object_member(<<"constructor">>) -> {'$namespace', bouy_object};
object_member(K) -> method(bouy_object, K, ?OBJECT_METHODS).

%% The member Key that a value of the type Module inherits: a method of the
%% prototype of Module, the constructor, or a member of Object.prototype.
-spec member(atom(), value(), [binary()]) -> value().
member(Module, K, Names) ->
    case to_key(K) of
        <<"constructor">> -> constructor(Module);
        Key -> method(Module, Key, Names)
    end.

method(Module, Key, Names) ->
    case lists:member(Key, Names) of
        true -> {'$method', Module, Key};
        false when Module =:= bouy_object -> undefined;
        false -> object_member(Key)
    end.

constructor(Module) ->
    case lists:member(Module, ?CONSTRUCTORS) of
        true -> {'$namespace', Module};
        false -> object_member(<<"constructor">>)
    end.

%% `C.name`, `C.prototype`, and `Error.captureStackTrace` of a class.
class_member({'$class', _, Name}, <<"name">>) -> Name;
class_member(Class, <<"prototype">>) -> {'$prototype', Class};
class_member(_Class, <<"captureStackTrace">>) -> {'$method', bouy_error, <<"captureStackTrace">>};
class_member(_Class, K) -> member(function, K, ?FUNCTION_METHODS).

%% A member of `X.prototype`, where Owner is the class or the namespace X.
prototype_member(Owner, <<"constructor">>) -> Owner;
prototype_member({'$namespace', bouy_object}, K) -> object_member(K);
prototype_member({'$namespace', Module}, K) ->
    case sample(Module) of
        none -> object_member(K);
        Sample -> get(Sample, K)
    end;
prototype_member({'$class', _, _}, <<"toString">>) -> {'$method', bouy_error, <<"toString">>};
prototype_member({'$class', _, _}, K) -> object_member(K).

%% A value whose members are those of the prototype of Module.
sample(bouy_array) -> [];
sample(bouy_string) -> <<>>;
sample(bouy_number) -> 0;
sample(bouy_date) -> {'$date', 'NaN'};
sample(bouy_map) -> bouy_map:new([]);
sample(bouy_set) -> bouy_set:new([]);
sample(_) -> none.

-spec set(value(), value(), value()) -> value().
set(O, K, V) when is_map(O) -> maps:put(to_key(K), V, O);
set(O, K, V) when is_list(O) -> bouy_array:set(O, K, V);
set(O, K, _) when ?IS_NULLISH(O) ->
    type_error(<<"Cannot set properties of ", (to_string(O))/binary, " (setting '", (to_key(K))/binary, "')">>);
set(O, K, _) when is_binary(O) ->
    type_error(<<"Cannot assign to read only property '", (to_key(K))/binary, "' of string '", O/binary, "'">>);
set(O, K, _) ->
    type_error(<<"Cannot create property '", (to_key(K))/binary, "' on ", (type_of(O))/binary, " '", (to_string(O))/binary, "'">>).

-spec delete(value(), value()) -> value().
delete(O, K) when is_map(O) -> maps:remove(to_key(K), O);
delete(O, K) when is_list(O) ->
    case to_index(K) of
        I when is_integer(I), I < length(O) -> bouy_array:set(O, I, undefined);
        _ -> O
    end;
delete(O, _) -> O.

%% ToPropertyKey.
-spec to_key(value()) -> binary().
to_key(K) when is_binary(K) -> K;
to_key(K) when is_integer(K) -> integer_to_binary(K);
to_key(K) -> to_string(K).

%% The array index that a property key names, or `none`.
-spec to_index(value()) -> non_neg_integer() | none.
to_index(I) when is_integer(I), I >= 0 -> I;
to_index(F) when is_float(F), F >= 0, F == trunc(F) -> trunc(F);
to_index(<<"0">>) -> 0;
to_index(<<C, _/binary>> = K) when C >= $1, C =< $9 ->
    try binary_to_integer(K) of
        I -> I
    catch
        error:badarg -> none
    end;
to_index(_) -> none.

%%% Literals and destructuring

-spec object([{value(), value()} | {'$spread', value()}]) -> map().
object(Entries) ->
    lists:foldl(fun object_entry/2, #{}, Entries).

object_entry({'$spread', Source}, Acc) -> maps:merge(Acc, maps:from_list(bouy_object:own_entries(Source)));
object_entry({Key, Value}, Acc) -> maps:put(to_key(Key), Value, Acc).

-spec array([{'$item', value()} | {'$spread', value()}]) -> list().
array(Entries) ->
    lists:flatmap(fun array_entry/1, Entries).

array_entry({'$item', Item}) -> [Item];
array_entry({'$spread', Source}) -> to_list(Source).

-spec object_rest(value(), [value()]) -> map().
object_rest(O, Keys) ->
    maps:without([to_key(K) || K <- Keys], maps:from_list(bouy_object:own_entries(O))).

-spec array_rest(value(), non_neg_integer()) -> list().
array_rest(V, N) ->
    drop(N, to_list(V)).

drop(0, List) -> List;
drop(N, [_ | Rest]) -> drop(N - 1, Rest);
drop(_, []) -> [].

%% The items that `for...of` and spreads visit.
-spec to_list(value()) -> list().
to_list(L) when is_list(L) -> L;
to_list(B) when is_binary(B) -> [<<C/utf8>> || <<C/utf8>> <= B];
to_list({'$map', _} = M) -> [[K, V] || {K, V} <- bouy_map:entries(M)];
to_list({'$set', _} = S) -> bouy_set:items(S);
to_list({'$iterator', _, Items}) -> Items;
to_list(V) -> type_error(<<(describe(V))/binary, " is not iterable">>).

%% The keys that `for...in` visits.
-spec keys(value()) -> [binary()].
keys(V) ->
    [Key || {Key, _} <- bouy_object:own_entries(V)].

%%% Errors

-spec caught(term(), list()) -> value().
caught({'$throw', Value}, _Stack) -> Value;
caught(Reason, Stack) -> bouy_error:from_erlang(Reason, Stack).

-spec no_method(value(), binary()) -> no_return().
no_method(R, Name) ->
    type_error(<<(describe(R))/binary, ".", (to_key(Name))/binary, " is not a function">>).

-spec read_error(null | undefined, value()) -> no_return().
read_error(O, K) ->
    type_error(<<"Cannot read properties of ", (to_string(O))/binary, " (reading '", (to_key(K))/binary, "')">>).

-spec type_error(binary()) -> no_return().
type_error(Message) ->
    bouy_error:throw(<<"TypeError">>, Message).

%% A short rendering of a value for error messages, like V8 prints a
%% literal: strings in double quotes, other values as `console.log` would,
%% cut after 40 characters.
-spec describe(value()) -> binary().
describe(V) when is_binary(V) ->
    <<"\"", V/binary, "\"">>;
describe(V) ->
    Text = bouy_console:inspect(V, 0),
    case prefix(Text, 40) of
        Text -> Text;
        Short -> <<Short/binary, "...">>
    end.

%% The first N code points of a UTF-8 binary.
-spec prefix(binary(), non_neg_integer()) -> binary().
prefix(Text, N) ->
    binary:part(Text, 0, prefix_size(Text, N, 0)).

prefix_size(_Text, 0, Size) ->
    Size;
prefix_size(Text, N, Size) ->
    case Text of
        <<_:Size/binary, C/utf8, _/binary>> -> prefix_size(Text, N - 1, Size + byte_size(<<C/utf8>>));
        <<_:Size/binary, _, _/binary>> -> prefix_size(Text, N - 1, Size + 1);
        _ -> Size
    end.

%% The JavaScript name of a global namespace module, or undefined.
-spec global_name(atom()) -> binary() | undefined.
global_name(bouy_array) -> <<"Array">>;
global_name(bouy_console) -> <<"console">>;
global_name(bouy_date) -> <<"Date">>;
global_name(bouy_error) -> <<"Error">>;
global_name(bouy_json) -> <<"JSON">>;
global_name(bouy_map) -> <<"Map">>;
global_name(bouy_math) -> <<"Math">>;
global_name(bouy_number) -> <<"Number">>;
global_name(bouy_object) -> <<"Object">>;
global_name(bouy_set) -> <<"Set">>;
global_name(bouy_string) -> <<"String">>;
global_name(bouy_task) -> <<"Promise">>;
global_name(_) -> undefined.

%% The constructor whose prototype holds the methods of a method value.
owner_name(boolean) -> <<"Boolean">>;
owner_name(function) -> <<"Function">>;
owner_name(bouy_iterator) -> <<"Iterator">>;
owner_name(Module) ->
    case global_name(Module) of
        undefined -> <<"Object">>;
        Name -> Name
    end.

%%% Process environment

-spec env(binary()) -> binary() | undefined.
env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> undefined;
        Value -> unicode:characters_to_binary(Value)
    end.

-spec argv() -> [binary()].
argv() ->
    persistent_term:get({bouy, argv}, []).

-spec structured_clone(value()) -> value().
structured_clone(V) -> V.

%%% Conversions for the runtime modules

%% ToIntegerOrInfinity: NaN becomes 0.
-spec to_integer(value()) -> integer() | 'Infinity' | '-Infinity'.
to_integer(V) ->
    case to_number(V) of
        I when is_integer(I) -> I;
        F when is_float(F) -> trunc(F);
        'NaN' -> 0;
        Infinity -> Infinity
    end.

%% A relative index argument, as `slice` takes it: negative counts from the
%% end, and the result lies in [0, Length].
-spec relative_index(value(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
relative_index(undefined, _Length, Default) -> Default;
relative_index(V, Length, _Default) ->
    case to_integer(V) of
        '-Infinity' -> 0;
        'Infinity' -> Length;
        I when I < 0 -> max(Length + I, 0);
        I -> min(I, Length)
    end.

%% An integer argument clamped to [Min, Max].
-spec clamp(value(), integer(), integer()) -> integer().
clamp(V, Min, Max) ->
    case to_integer(V) of
        '-Infinity' -> Min;
        'Infinity' -> Max;
        I -> max(Min, min(I, Max))
    end.

%% The term under which Map and Set store a value: numbers that are equal
%% under SameValueZero share one term. An integral float below 1e21 becomes
%% an integer, which prints the same; beyond, an integer that a double holds
%% exactly becomes that double.
-spec collection_key(value()) -> value().
collection_key(F) when is_float(F), abs(F) < 1.0e21, F == trunc(F) -> trunc(F);
collection_key(I) when is_integer(I), abs(I) >= 1.0e21 -> exact_double(I);
collection_key(V) -> V.

exact_double(I) ->
    try float(I) of
        F when trunc(F) =:= I -> F;
        _ -> I
    catch
        error:badarg -> I
    end.

-spec same_value_zero(value(), value()) -> boolean().
same_value_zero('NaN', 'NaN') -> true;
same_value_zero(A, B) -> strict_eq(A, B).

%% `Namespace.x` for a module that exposes the functions `Names`. A
%% constructor namespace also has `name` and `prototype`.
-spec member_function(module(), binary(), [binary()]) -> term().
member_function(Module, Name, Names) ->
    case lists:member(Name, Names) of
        true ->
            Function = binary_to_atom(Name),
            fun Module:Function/1;
        false ->
            constructor_member(Module, Name, lists:member(Module, ?CONSTRUCTORS))
    end.

constructor_member(Module, <<"name">>, true) -> global_name(Module);
constructor_member(Module, <<"prototype">>, true) -> {'$prototype', {'$namespace', Module}};
constructor_member(_Module, _Name, _Constructor) -> undefined.
