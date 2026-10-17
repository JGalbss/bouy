%% The JSON family: JSON over the heap of a reference-semantics realm. Object
%% keys keep insertion order, toJSON and a replacer function apply, and parse
%% builds heap objects through the decoders of OTP's json module. The text
%% is built as UTF-8 and becomes a string of the engine at the end.
-module(bouy_ref_json).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, stringify/3, parse/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'JSON', bouy_ref_realm:record(object, ?OBJECT_PROTO, ?METHODS(<<"JSON">>, [<<"stringify">>, <<"parse">>]) ++ [{?SYM(toStringTag), <<"JSON">>}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"JSON">>, {'$o', 'JSON'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"JSON">>, <<"stringify">>, _This, Args) ->
    [Value, Replacer, Space] = [bouy_ref_realm:arg(N, Args) || N <- [1, 2, 3]],
    stringify(Value, Replacer, Space);
method(<<"JSON">>, <<"parse">>, _This, Args) -> parse(bouy_ref:to_string(bouy_ref_realm:arg(1, Args))).

-spec stringify(term(), term(), term()) -> bouy_ref_string:js_string() | undefined.
stringify(Value, Replacer, Space) ->
    Gap = gap(Space),
    Holder = bouy_heap:object({'$o', 'Object.prototype'}, [{<<>>, Value}]),
    State = #{replacer => replacer(Replacer), gap => Gap, stack => []},
    case property(<<>>, Holder, State, <<>>) of
        undefined -> undefined;
        Text -> bouy_ref_string:from_utf8(iolist_to_binary(Text))
    end.

replacer({'$f', _, _} = F) -> F;
replacer(_) -> undefined.

gap(N) when is_number(N) -> binary:copy(<<" ">>, max(0, min(10, trunc(N))));
gap(S) when ?IS_STRING(S) -> bouy_ref_string:to_utf8(bouy_ref_string:slice(S, 0, min(10, bouy_ref_string:length_of(S))));
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
value(S, _, _) when ?IS_STRING(S) -> quote(S);
value(I, _, _) when is_integer(I) -> integer_to_binary(I);
value(F, _, _) when is_float(F) -> bouy_ref_number:to_string(F);
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
                                          Text -> {true, [quote(bouy_ref:to_string(bouy_heap:key_to_value(K))), Colon, Text]}
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

%% QuoteJSONString, with a lone surrogate escaped as JSON.stringify does.
quote(S) -> [$", [escape(C) || C <- bouy_ref_string:code_points(S)], $"].

escape($") -> <<"\\\"">>;
escape($\\) -> <<"\\\\">>;
escape($\b) -> <<"\\b">>;
escape($\f) -> <<"\\f">>;
escape($\n) -> <<"\\n">>;
escape($\r) -> <<"\\r">>;
escape($\t) -> <<"\\t">>;
escape(C) when C < 16#20; C >= 16#D800, C =< 16#DFFF -> io_lib:format("\\u~4.16.0b", [C]);
escape(C) -> <<C/utf8>>.

wrap(Open, Close, [], _Gap, _Indent, _Inner) -> [Open, Close];
wrap(Open, Close, Parts, <<>>, _Indent, _Inner) -> [Open, lists:join(<<",">>, Parts), Close];
wrap(Open, Close, Parts, _Gap, Indent, Inner) ->
    [Open, $\n, Inner, lists:join([<<",\n">>, Inner], Parts), $\n, Indent, Close].

-spec parse(bouy_ref_string:js_string()) -> term().
parse(Text) ->
    Decoders = #{
        string => fun bouy_ref_string:from_utf8/1,
        integer => fun(B) -> bouy_ref_number:canonical(binary_to_integer(B)) end,
        float => fun(B) -> bouy_ref_number:canonical(binary_to_float(B)) end,
        array_start => fun(_) -> [] end,
        array_push => fun(V, Acc) -> [V | Acc] end,
        array_finish => fun(Acc, Old) -> {bouy_heap:new_array(lists:reverse(Acc)), Old} end,
        object_start => fun(_) -> [] end,
        object_push => fun(K, V, Acc) -> [{bouy_heap:to_key(K), V} | Acc] end,
        object_finish => fun(Acc, Old) -> {bouy_heap:object({'$o', 'Object.prototype'}, lists:reverse(Acc)), Old} end,
        null => null
    },
    try json:decode(bouy_ref_string:to_utf8(Text), ok, Decoders) of
        {Value, ok, Rest} ->
            case string:trim(Rest) of
                <<>> -> Value;
                _ -> syntax_error(Text)
            end
    catch
        error:_ -> syntax_error(Text)
    end.

-spec syntax_error(bouy_ref_string:js_string()) -> no_return().
syntax_error(Text) ->
    bouy_heap:throw_error('SyntaxError', bouy_ref_string:concat(<<"Unexpected token in JSON: ">>, Text)).
