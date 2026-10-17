%% The JSON family: JSON.parse with a reviver and its source context,
%% JSON.stringify with a replacer function or property list, a gap, and
%% toJSON, and JSON.rawJSON and JSON.isRawJSON.
%%
%% The parser reads the code units of a string of the engine directly, so
%% an escaped lone surrogate stays one code unit, and object keys keep the
%% order of the text, with a repeated key keeping its first position.
-module(bouy_ref_json).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, stringify/3, parse/1]).

-import(bouy_ref_realm, [arg/2, record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'JSON', record(object, ?OBJECT_PROTO, ?METHODS(<<"JSON">>, [{<<"parse">>, 2}, {<<"stringify">>, 3}, {<<"rawJSON">>, 1}, {<<"isRawJSON">>, 1}])
          ++ [{?SYM(toStringTag), <<"JSON">>, 4}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"JSON">>, {'$o', 'JSON'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"JSON">>, <<"stringify">>, _This, Args) -> stringify(arg(1, Args), arg(2, Args), arg(3, Args));
method(<<"JSON">>, <<"parse">>, _This, Args) ->
    Text = bouy_ref:to_string(arg(1, Args)),
    case arg(2, Args) of
        {'$f', _, _} = Reviver ->
            {Value, Record} = parse_text(Text, true),
            Root = bouy_heap:object(?OBJECT_PROTO, [{<<>>, Value}]),
            internalize(Root, <<>>, Reviver, Record);
        _ ->
            {Value, _} = parse_text(Text, false),
            Value
    end;
method(<<"JSON">>, <<"rawJSON">>, _This, Args) -> raw_json(bouy_ref:to_string(arg(1, Args)));
method(<<"JSON">>, <<"isRawJSON">>, _This, Args) ->
    V = arg(1, Args),
    ?IS_OBJECT(V) andalso bouy_heap:class_of(V) =:= raw_json.

%%% JSON.parse

-spec parse(bouy_ref_string:js_string()) -> term().
parse(Text) ->
    {Value, _} = parse_text(Text, false),
    Value.

%% The value of the text, and with Records, the parse record of each value:
%% {Value, Source} for a primitive, {Value, [Record]} for an array, and
%% {Value, #{Key => Record}} for an object.
parse_text(Text, Records) ->
    {Width, Bytes} = case Text of
        {'$u16', W} -> {16, W};
        B -> {8, B}
    end,
    State = #{width => Width, text => Text, records => Records},
    {Value, Record, Rest, Pos} = parse_value(skip(Bytes, Width), State, offset(Bytes, Bytes, Width)),
    case skip(Rest, Width) of
        <<>> -> {Value, Record};
        Trailing -> at(<<"Unexpected non-whitespace character after JSON">>, Trailing, State, Pos)
    end.

offset(All, Rest, Width) -> (byte_size(All) - byte_size(Rest)) * 8 div Width.

skip(Bin, Width) ->
    case Bin of
        <<C:Width, Rest/binary>> when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> skip(Rest, Width);
        _ -> Bin
    end.

%% A value at Bin: {Value, Record, Rest, Position after}.
parse_value(Bin, #{width := W} = State, _From) ->
    Pos = position(Bin, State),
    case Bin of
        <<${:W, Rest/binary>> -> parse_object(skip(Rest, W), State, []);
        <<$[:W, Rest/binary>> -> parse_array(skip(Rest, W), State, []);
        <<$":W, Rest/binary>> ->
            {S, Rest1} = string(Rest, State, []),
            {S, primitive_record(S, Pos, Rest1, State), Rest1, position(Rest1, State)};
        <<"t", _/binary>> when W =:= 8 -> literal(Bin, <<"true">>, true, State);
        <<"f", _/binary>> when W =:= 8 -> literal(Bin, <<"false">>, false, State);
        <<"n", _/binary>> when W =:= 8 -> literal(Bin, <<"null">>, null, State);
        <<$t:16, _/binary>> -> literal(Bin, <<"true">>, true, State);
        <<$f:16, _/binary>> -> literal(Bin, <<"false">>, false, State);
        <<$n:16, _/binary>> -> literal(Bin, <<"null">>, null, State);
        <<C:W, _/binary>> when C =:= $-; C >= $0, C =< $9 ->
            {N, Rest} = number(Bin, State),
            {N, primitive_record(N, Pos, Rest, State), Rest, position(Rest, State)};
        _ -> unexpected(Bin, State, Pos)
    end.

%% The position of Bin in the text, in code units.
position(Bin, #{text := Text, width := W}) ->
    Size = case Text of
        {'$u16', B} -> byte_size(B);
        B -> byte_size(B)
    end,
    (Size - byte_size(Bin)) * 8 div W.

primitive_record(_Value, _Start, _Rest, #{records := false}) -> none;
primitive_record(Value, Start, Rest, #{text := Text} = State) ->
    {Value, bouy_ref_string:slice(Text, Start, position(Rest, State))}.

literal(Bin, Word, Value, #{width := W} = State) ->
    Units = << <<C:W>> || <<C>> <= Word >>,
    Size = byte_size(Units),
    case Bin of
        <<Units:Size/binary, Rest/binary>> ->
            {Value, primitive_record(Value, position(Bin, State), Rest, State), Rest, position(Rest, State)};
        _ -> mismatch(Bin, Word, State)
    end.

%% The first character where the text leaves a literal: the end of the
%% input, or an unexpected token.
mismatch(Bin, <<C, Word/binary>>, #{width := W} = State) ->
    case Bin of
        <<C:W, Rest/binary>> -> mismatch(Rest, Word, State);
        _ -> unexpected(Bin, State, position(Bin, State))
    end.

parse_object(<<$}:8, Rest/binary>>, #{width := 8} = State, []) -> finish_object([], Rest, State);
parse_object(<<$}:16, Rest/binary>>, #{width := 16} = State, []) -> finish_object([], Rest, State);
parse_object(Bin, #{width := W} = State, Acc) ->
    case Bin of
        <<$":W, Rest/binary>> ->
            {Key, Rest1} = string(Rest, State, []),
            case skip(Rest1, W) of
                <<$::W, Rest2/binary>> ->
                    {V, Record, Rest3, _} = parse_value(skip(Rest2, W), State, 0),
                    Acc1 = [{Key, V, Record} | Acc],
                    case skip(Rest3, W) of
                        <<$,:W, Rest4/binary>> ->
                            case skip(Rest4, W) of
                                <<$":W, _/binary>> = Next -> parse_object(Next, State, Acc1);
                                Other -> expected(<<"double-quoted property name">>, Other, State)
                            end;
                        <<$}:W, Rest4/binary>> -> finish_object(Acc1, Rest4, State);
                        Other -> expected(<<"',' or '}' after property value">>, Other, State)
                    end;
                Other -> expected(<<"':' after property name">>, Other, State)
            end;
        Other -> expected(<<"property name or '}'">>, Other, State)
    end.

finish_object(Acc, Rest, #{records := Records} = State) ->
    Members = lists:reverse(Acc),
    O = bouy_heap:object(?OBJECT_PROTO, [{bouy_heap:to_key(K), V} || {K, V, _} <- Members]),
    Record = case Records of
        false -> none;
        true -> {O, maps:from_list([{bouy_heap:to_key(K), R} || {K, _, R} <- Members])}
    end,
    {O, Record, Rest, position(Rest, State)}.

parse_array(<<$]:8, Rest/binary>>, #{width := 8} = State, []) -> finish_array([], Rest, State);
parse_array(<<$]:16, Rest/binary>>, #{width := 16} = State, []) -> finish_array([], Rest, State);
parse_array(Bin, #{width := W} = State, Acc) ->
    {V, Record, Rest, _} = parse_value(Bin, State, 0),
    Acc1 = [{V, Record} | Acc],
    case skip(Rest, W) of
        <<$,:W, Rest1/binary>> -> parse_array(skip(Rest1, W), State, Acc1);
        <<$]:W, Rest1/binary>> -> finish_array(Acc1, Rest1, State);
        Other -> expected(<<"',' or ']' after array element">>, Other, State)
    end.

finish_array(Acc, Rest, #{records := Records} = State) ->
    Items = lists:reverse(Acc),
    A = bouy_heap:new_array([V || {V, _} <- Items]),
    Record = case Records of
        false -> none;
        true -> {A, [R || {_, R} <- Items]}
    end,
    {A, Record, Rest, position(Rest, State)}.

%% The code units of a string up to its closing quote.
string(Bin, #{width := W} = State, Acc) ->
    case Bin of
        <<$":W, Rest/binary>> -> {bouy_ref_string:from_units(lists:reverse(Acc)), Rest};
        <<$\\:W, Rest/binary>> ->
            case Rest of
                <<$":W, R/binary>> -> string(R, State, [$" | Acc]);
                <<$\\:W, R/binary>> -> string(R, State, [$\\ | Acc]);
                <<$/:W, R/binary>> -> string(R, State, [$/ | Acc]);
                <<$b:W, R/binary>> -> string(R, State, [$\b | Acc]);
                <<$f:W, R/binary>> -> string(R, State, [$\f | Acc]);
                <<$n:W, R/binary>> -> string(R, State, [$\n | Acc]);
                <<$r:W, R/binary>> -> string(R, State, [$\r | Acc]);
                <<$t:W, R/binary>> -> string(R, State, [$\t | Acc]);
                <<$u:W, A:W, B:W, C:W, D:W, R/binary>> ->
                    case hex([A, B, C, D]) of
                        error -> at(<<"Bad Unicode escape">>, bad_hex(Rest, State), State);
                        U -> string(R, State, [U | Acc])
                    end;
                <<$u:W, _/binary>> -> at(<<"Bad Unicode escape">>, bad_hex(Rest, State), State);
                <<>> -> at(<<"Unterminated string">>, Rest, State);
                _ -> at(<<"Bad escaped character">>, Rest, State)
            end;
        <<C:W, Rest/binary>> when C >= 16#20 -> string(Rest, State, [C | Acc]);
        <<>> -> at(<<"Unterminated string">>, Bin, State);
        _ -> at(<<"Bad control character in string literal">>, Bin, State)
    end.

%% The text at the first character after \u that is not a hex digit.
bad_hex(<<_:8, Rest/binary>>, #{width := 8}) -> first_non_hex(Rest, 8);
bad_hex(<<_:16, Rest/binary>>, #{width := 16}) -> first_non_hex(Rest, 16).

first_non_hex(Bin, W) ->
    case Bin of
        <<C:W, Rest/binary>> when (C >= $0 andalso C =< $9); (C >= $a andalso C =< $f); (C >= $A andalso C =< $F) ->
            first_non_hex(Rest, W);
        _ -> Bin
    end.

hex(Digits) ->
    lists:foldl(fun(_, error) -> error;
                   (D, Acc) when D >= $0, D =< $9 -> Acc * 16 + D - $0;
                   (D, Acc) when D >= $a, D =< $f -> Acc * 16 + D - $a + 10;
                   (D, Acc) when D >= $A, D =< $F -> Acc * 16 + D - $A + 10;
                   (_, _) -> error
                end, 0, Digits).

%% A number: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
number(Bin, #{width := W} = State) ->
    {Sign, Rest0} = case Bin of
        <<$-:W, R/binary>> -> {"-", R};
        _ -> {"", Bin}
    end,
    {Int, Rest1} = case Rest0 of
        <<$0:W, Next:W, _/binary>> when Next >= $0, Next =< $9 ->
            <<_:W, After/binary>> = Rest0,
            at(<<"Unexpected number">>, After, State);
        <<$0:W, R1/binary>> -> {"0", R1};
        <<C:W, _/binary>> when C >= $1, C =< $9 -> digits(Rest0, W, []);
        _ -> at(<<"No number after minus sign">>, Rest0, State)
    end,
    {Frac, Rest2} = case Rest1 of
        <<$.:W, R2/binary>> ->
            case digits(R2, W, []) of
                {[], _} -> at(<<"Unterminated fractional number">>, R2, State);
                {F, R3} -> {"." ++ F, R3}
            end;
        _ -> {"", Rest1}
    end,
    {Exp, Rest3} = case Rest2 of
        <<E:W, R4/binary>> when E =:= $e; E =:= $E ->
            {ESign, R5} = case R4 of
                <<$+:W, R6/binary>> -> {"+", R6};
                <<$-:W, R6/binary>> -> {"-", R6};
                _ -> {"", R4}
            end,
            case digits(R5, W, []) of
                {[], _} -> at(<<"Exponent part is missing a number">>, R5, State);
                {D, R7} -> {"e" ++ ESign ++ D, R7}
            end;
        _ -> {"", Rest2}
    end,
    {Value, []} = bouy_ref_number:parse_decimal(Sign ++ Int ++ Frac ++ Exp),
    {Value, Rest3}.

digits(Bin, W, Acc) ->
    case Bin of
        <<C:W, Rest/binary>> when C >= $0, C =< $9 -> digits(Rest, W, [C | Acc]);
        _ -> {lists:reverse(Acc), Bin}
    end.

%% An unexpected token, with the text around it as V8 shows it.
-spec unexpected(binary(), map(), non_neg_integer()) -> no_return().
unexpected(<<>>, _State, _Pos) -> end_of_input();
unexpected(Bin, #{width := W, text := Text}, Pos) ->
    <<C:W, _/binary>> = Bin,
    Token = bouy_ref_string:from_units([C]),
    Length = bouy_ref_string:length_of(Text),
    Shown = case Length < 21 of
        true -> [<<"\"">>, Text, <<"\"">>];
        false ->
            Start = max(0, Pos - 10),
            End = min(Length, Pos + 10),
            Part = bouy_ref_string:slice(Text, Start, End),
            [case Start of 0 -> <<>>; _ -> <<"...">> end, <<"\"">>, Part, <<"\"">>,
             case End of Length -> <<>>; _ -> <<"...">> end]
    end,
    syntax_error(bouy_ref_string:concat([<<"Unexpected token '">>, Token, <<"', ">> | Shown] ++ [<<" is not valid JSON">>])).

-spec expected(binary(), binary(), map()) -> no_return().
expected(What, Bin, State) -> at(<<"Expected ", What/binary>>, Bin, State).

%% A message with the position of Bin, and its line and column.
-spec at(binary(), binary(), map()) -> no_return().
at(Message, Bin, State) -> at(Message, Bin, State, position(Bin, State)).

-spec at(binary(), binary(), map(), non_neg_integer()) -> no_return().
at(Message, _Bin, #{text := Text}, Pos) ->
    Before = bouy_ref_string:units(bouy_ref_string:slice(Text, 0, Pos)),
    Line = 1 + length([U || U <- Before, U =:= $\n]),
    Column = 1 + length(lists:takewhile(fun(U) -> U =/= $\n end, lists:reverse(Before))),
    syntax_error(iolist_to_binary([Message, <<" in JSON at position ">>, integer_to_binary(Pos), <<" (line ">>,
                                   integer_to_binary(Line), <<" column ">>, integer_to_binary(Column), <<")">>])).

-spec end_of_input() -> no_return().
end_of_input() -> syntax_error(<<"Unexpected end of JSON input">>).

-spec syntax_error(bouy_ref_string:js_string()) -> no_return().
syntax_error(Message) -> bouy_heap:throw_error('SyntaxError', Message).

%% InternalizeJSONProperty, with the source of each primitive that the
%% reviver has not replaced.
internalize(Holder, Name, Reviver, Record) ->
    Val = bouy_ref:get(Holder, Name),
    {Context, Children} = case Record of
        {V, Source} when V =:= Val, not ?IS_OBJECT(V), Source =/= none ->
            {bouy_heap:object(?OBJECT_PROTO, [{<<"source">>, Source}]), none};
        {V, Kids} when V =:= Val, ?IS_OBJECT(V) -> {bouy_heap:new_object(?OBJECT_PROTO), Kids};
        _ -> {bouy_heap:new_object(?OBJECT_PROTO), none}
    end,
    case ?IS_OBJECT(Val) of
        false -> ok;
        true ->
            case bouy_ref_array:is_array(Val) of
                true ->
                    Len = bouy_ref_array:length_of(Val),
                    [revive(Val, I, Reviver, child(Children, I)) || I <- seq(0, Len - 1)];
                false ->
                    [revive(Val, K, Reviver, child(Children, K)) || K <- bouy_heap:enumerable_keys(Val)]
            end
    end,
    bouy_ref:call(Reviver, Holder, [bouy_heap:key_to_value(Name), Val, Context]).

revive(O, K, Reviver, Record) ->
    case internalize(O, K, Reviver, Record) of
        undefined ->
            try bouy_heap:delete(O, K)
            catch error:{'$throw', _} -> false
            end;
        V -> define_data(O, K, V)
    end.

%% CreateDataProperty, which returns false instead of throwing.
define_data(O, K, V) ->
    case bouy_heap:get_own(O, K) of
        {data, _, Bits} when Bits band 4 =:= 0 -> false;
        {accessor, _, _, Bits} when Bits band 4 =:= 0 -> false;
        _ -> bouy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true})
    end.

child(none, _K) -> none;
child(Kids, I) when is_list(Kids), is_integer(I), I < length(Kids) -> lists:nth(I + 1, Kids);
child(Kids, _I) when is_list(Kids) -> none;
child(Kids, K) when is_map(Kids) -> maps:get(K, Kids, none);
child(_, _) -> none.

seq(From, To) when From > To -> [];
seq(From, To) -> lists:seq(From, To).

%%% JSON.rawJSON

raw_json(Text) ->
    Units = bouy_ref_string:units(Text),
    Blank = fun(C) -> C =:= $\t orelse C =:= $\n orelse C =:= $\r orelse C =:= $\s end,
    (Units =:= [] orelse Blank(hd(Units)) orelse Blank(lists:last(Units))) andalso
        syntax_error(<<"Invalid value for JSON.rawJSON">>),
    (hd(Units) =:= ${ orelse hd(Units) =:= $[) andalso syntax_error(<<"Invalid value for JSON.rawJSON">>),
    _ = parse(Text),
    O = bouy_heap:new_exotic(raw_json, null, none),
    bouy_heap:define(O, <<"rawJSON">>, #{value => Text, writable => true, enumerable => true, configurable => true}),
    bouy_heap:freeze(O).

%%% JSON.stringify

-spec stringify(term(), term(), term()) -> bouy_ref_string:js_string() | undefined.
stringify(Value, Replacer, Space) ->
    {ReplacerFunction, PropertyList} = case Replacer of
        {'$f', _, _} -> {Replacer, undefined};
        {'$o', _} ->
            case bouy_ref_array:is_array(Replacer) of
                true -> {undefined, property_list(Replacer)};
                false -> {undefined, undefined}
            end;
        _ -> {undefined, undefined}
    end,
    Gap = gap(unwrap_space(Space)),
    Wrapper = bouy_heap:object(?OBJECT_PROTO, [{<<>>, Value}]),
    State = #{replacer => ReplacerFunction, keys => PropertyList, gap => Gap, stack => []},
    case property(<<>>, Wrapper, State, <<>>) of
        undefined -> undefined;
        Text -> bouy_ref_string:from_utf8(iolist_to_binary(Text))
    end.

%% The keys of an array replacer: strings, numbers, and their objects, each
%% once.
property_list(A) ->
    Items = [bouy_ref:get(A, I) || I <- seq(0, bouy_ref_array:length_of(A) - 1)],
    Keys = lists:filtermap(fun(V) ->
                                   case V of
                                       S when ?IS_STRING(S) -> {true, S};
                                       N when ?IS_NUMBER(N) -> {true, bouy_ref:to_string(N)};
                                       {'$o', _} = O ->
                                           case bouy_heap:class_of(O) of
                                               C when C =:= string; C =:= number -> {true, bouy_ref:to_string(O)};
                                               _ -> false
                                           end;
                                       _ -> false
                                   end
                           end, Items),
    unique([bouy_heap:to_key(K) || K <- Keys], []).

unique([], Acc) -> lists:reverse(Acc);
unique([K | Rest], Acc) ->
    case lists:member(K, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [K | Acc])
    end.

unwrap_space({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        number -> bouy_ref:to_number(O);
        string -> bouy_ref:to_string(O);
        _ -> O
    end;
unwrap_space(V) -> V.

gap(N) when ?IS_NUMBER(N) ->
    Count = case bouy_ref_number:to_integer_or_infinity(N) of
        'Infinity' -> 10;
        '-Infinity' -> 0;
        I -> max(0, min(10, I))
    end,
    binary:copy(<<" ">>, Count);
gap(S) when ?IS_STRING(S) -> bouy_ref_string:to_utf8(bouy_ref_string:slice(S, 0, min(10, bouy_ref_string:length_of(S))));
gap(_) -> <<>>.

%% SerializeJSONProperty.
property(Key, Holder, #{replacer := Replacer} = State, Indent) ->
    Value0 = bouy_ref:get(Holder, Key),
    Value1 = case ?IS_OBJECT(Value0) orelse is_big_int(Value0) of
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
    value(unwrap(Value), State, Indent).

is_big_int({'$bigint', _}) -> true;
is_big_int(_) -> false.

unwrap({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        number -> bouy_ref:to_number(O);
        string -> bouy_ref:to_string(O);
        boolean -> bouy_heap:slots(O);
        bigint -> bouy_heap:slots(O);
        _ -> O
    end;
unwrap(V) -> V.

value(null, _, _) -> <<"null">>;
value(true, _, _) -> <<"true">>;
value(false, _, _) -> <<"false">>;
value(S, _, _) when ?IS_STRING(S) -> quote(S);
value(I, _, _) when is_integer(I) -> integer_to_binary(I);
value(F, _, _) when is_float(F) -> bouy_ref_number:to_string(F);
value(A, _, _) when A =:= 'NaN'; A =:= 'Infinity'; A =:= '-Infinity' -> <<"null">>;
value({'$bigint', _}, _, _) -> bouy_ref:type_error(<<"Do not know how to serialize a BigInt">>);
value({'$o', _} = O, State, Indent) ->
    %% IsArray: a proxy of an array serializes as an array too.
    case bouy_heap:class_of(O) of
        raw_json -> bouy_ref_string:to_utf8(bouy_ref:get(O, <<"rawJSON">>));
        _ ->
            case bouy_ref_object:is_array(O) of
                true -> array(O, enter(O, State), Indent);
                false -> object(O, enter(O, State), Indent)
            end
    end;
value(_, _, _) -> undefined.

enter(O, #{stack := Stack} = State) ->
    lists:member(O, Stack) andalso bouy_ref:type_error(<<"Converting circular structure to JSON">>),
    State#{stack := [O | Stack]}.

object(O, #{gap := Gap, keys := PropertyList} = State, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Colon = case Gap of
        <<>> -> <<":">>;
        _ -> <<": ">>
    end,
    Keys = case PropertyList of
        undefined -> bouy_heap:enumerable_keys(O);
        _ -> PropertyList
    end,
    Members = lists:filtermap(fun(K) ->
                                      case property(K, O, State, Inner) of
                                          undefined -> false;
                                          Text -> {true, [quote(bouy_ref:to_string(bouy_heap:key_to_value(K))), Colon, Text]}
                                      end
                              end, Keys),
    wrap(<<"{">>, <<"}">>, Members, Gap, Indent, Inner).

array(A, #{gap := Gap} = State, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Items = [case property(I, A, State, Inner) of
                 undefined -> <<"null">>;
                 Text -> Text
             end || I <- seq(0, bouy_ref_array:length_of(A) - 1)],
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
