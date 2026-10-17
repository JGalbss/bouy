%% JSON over the heap of a reference-semantics realm (spike): object keys
%% keep insertion order, toJSON and a replacer function apply, and parse
%% builds heap objects through the decoders of OTP's json module.
-module(bouy_ref_json).

-export([stringify/3, parse/1]).

-define(IS_OBJECT(V), (is_tuple(V) andalso (element(1, V) =:= '$o' orelse element(1, V) =:= '$f'))).

-spec stringify(term(), term(), term()) -> binary() | undefined.
stringify(Value, Replacer, Space) ->
    Gap = gap(Space),
    Holder = bouy_heap:object({'$o', 'Object.prototype'}, [{<<>>, Value}]),
    State = #{replacer => replacer(Replacer), gap => Gap, stack => []},
    case property(<<>>, Holder, State, <<>>) of
        undefined -> undefined;
        Text -> iolist_to_binary(Text)
    end.

replacer({'$f', _, _} = F) -> F;
replacer(_) -> undefined.

gap(N) when is_number(N) -> binary:copy(<<" ">>, max(0, min(10, trunc(N))));
gap(S) when is_binary(S) -> string:slice(S, 0, 10);
gap(_) -> <<>>.

%% SerializeJSONProperty.
property(Key, Holder, #{replacer := Replacer} = State, Indent) ->
    Value0 = bouy_ref:get(Holder, Key),
    Value1 = case ?IS_OBJECT(Value0) of
        true ->
            case bouy_ref:get(Value0, <<"toJSON">>) of
                {'$f', _, _} = ToJson -> bouy_ref:call(ToJson, Value0, [bouy_heap:key_to_value(Key)]);
                _ -> Value0
            end;
        false ->
            Value0
    end,
    Value = case Replacer of
        undefined -> Value1;
        _ -> bouy_ref:call(Replacer, Holder, [bouy_heap:key_to_value(Key), Value1])
    end,
    value(Value, State, Indent).

value(null, _, _) -> <<"null">>;
value(true, _, _) -> <<"true">>;
value(false, _, _) -> <<"false">>;
value(S, _, _) when is_binary(S) -> json:encode_binary(S);
value(I, _, _) when is_integer(I) -> integer_to_binary(I);
value(F, _, _) when is_float(F) -> bouy_number:to_string(F);
value(A, _, _) when A =:= 'NaN'; A =:= 'Infinity'; A =:= '-Infinity' -> <<"null">>;
value({'$o', _} = O, State, Indent) ->
    case bouy_heap:class_of(O) of
        array -> array(O, enter(O, State), Indent);
        _ -> object(O, enter(O, State), Indent)
    end;
value(_, _, _) -> undefined.

enter(O, #{stack := Stack} = State) ->
    lists:member(O, Stack) andalso bouy_ref:type_error(<<"Converting circular structure to JSON">>),
    State#{stack := [O | Stack]}.

object(O, #{gap := Gap} = State, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Colon = case Gap of
        <<>> -> <<":">>;
        _ -> <<": ">>
    end,
    Members = lists:filtermap(fun(K) ->
                                      case property(K, O, State, Inner) of
                                          undefined -> false;
                                          Text -> {true, [json:encode_binary(bouy_ref:to_string(bouy_heap:key_to_value(K))), Colon, Text]}
                                      end
                              end, bouy_heap:enumerable_keys(O)),
    wrap(<<"{">>, <<"}">>, Members, Gap, Indent, Inner).

array(A, #{gap := Gap} = State, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Items = [case property(I, A, State, Inner) of
                 undefined -> <<"null">>;
                 Text -> Text
             end || I <- lists:seq(0, bouy_heap:array_length(A) - 1)],
    wrap(<<"[">>, <<"]">>, Items, Gap, Indent, Inner).

wrap(Open, Close, [], _Gap, _Indent, _Inner) -> [Open, Close];
wrap(Open, Close, Parts, <<>>, _Indent, _Inner) -> [Open, lists:join(<<",">>, Parts), Close];
wrap(Open, Close, Parts, _Gap, Indent, Inner) ->
    [Open, $\n, Inner, lists:join([<<",\n">>, Inner], Parts), $\n, Indent, Close].

-spec parse(binary()) -> term().
parse(Text) ->
    Decoders = #{
        array_start => fun(_) -> [] end,
        array_push => fun(V, Acc) -> [V | Acc] end,
        array_finish => fun(Acc, Old) -> {bouy_heap:new_array(lists:reverse(Acc)), Old} end,
        object_start => fun(_) -> [] end,
        object_push => fun(K, V, Acc) -> [{bouy_heap:to_key(K), V} | Acc] end,
        object_finish => fun(Acc, Old) -> {bouy_heap:object({'$o', 'Object.prototype'}, lists:reverse(Acc)), Old} end,
        null => null
    },
    try json:decode(Text, ok, Decoders) of
        {Value, ok, Rest} ->
            case string:trim(Rest) of
                <<>> -> Value;
                _ -> syntax_error(Text)
            end
    catch
        error:_ -> syntax_error(Text)
    end.

-spec syntax_error(binary()) -> no_return().
syntax_error(Text) ->
    bouy_heap:throw_error('SyntaxError', <<"Unexpected token in JSON: ", Text/binary>>).
