%% The `JSON` namespace. `stringify` matches JSON.stringify byte for byte
%% for the values Bouy has; object keys come out in Erlang term order.
%% `parse` uses the OTP `json` module.
-module(bouy_json).

-export(['$member'/1, stringify/1, parse/1]).

-define(FUNCTIONS, [<<"parse">>, <<"stringify">>]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%%% stringify

%% `JSON.stringify(value, replacer, space)`. A replacer must be null.
-spec stringify(list()) -> binary() | undefined.
stringify(Args) ->
    case bouy_rt:arg(2, Args) of
        Replacer when Replacer =:= undefined; Replacer =:= null -> ok;
        _ -> bouy_error:throw(<<"TypeError">>, <<"JSON.stringify supports no replacer: pass null">>)
    end,
    case encode(<<>>, bouy_rt:arg(1, Args), gap(bouy_rt:arg(3, Args)), <<>>) of
        undefined -> undefined;
        Text -> iolist_to_binary(Text)
    end.

gap(N) when is_number(N) -> binary:copy(<<" ">>, max(0, min(10, erlang:trunc(N))));
gap(S) when is_binary(S) -> binary:part(S, 0, min(byte_size(S), 10));
gap(_) -> <<>>.

%% The JSON text of a value, or undefined for a value that JSON omits.
encode(Key, Value, Gap, Indent) ->
    serialize(to_json(Key, Value), Gap, Indent).

to_json(_Key, {'$date', _} = Date) -> bouy_date:call(<<"toJSON">>, Date, []);
to_json(Key, #{<<"toJSON">> := F}) when is_function(F, 1) -> F([Key]);
to_json(_Key, Value) -> Value.

serialize(null, _, _) -> <<"null">>;
serialize(true, _, _) -> <<"true">>;
serialize(false, _, _) -> <<"false">>;
serialize(N, _, _) when is_number(N) -> bouy_number:to_string(N);
serialize(N, _, _) when N =:= 'NaN'; N =:= 'Infinity'; N =:= '-Infinity' -> <<"null">>;
serialize(S, _, _) when is_binary(S) -> quote(S);
serialize(L, Gap, Indent) when is_list(L) -> array(L, Gap, Indent);
serialize(#{<<"$error">> := true} = Error, Gap, Indent) -> object(bouy_error:fields(Error), Gap, Indent);
serialize(M, Gap, Indent) when is_map(M) -> object(M, Gap, Indent);
serialize(undefined, _, _) -> undefined;
serialize(F, _, _) when is_function(F) -> undefined;
serialize({'$class', _, _}, _, _) -> undefined;
serialize(_, _, _) -> <<"{}">>.

array([], _Gap, _Indent) ->
    <<"[]">>;
array(Items, Gap, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Encoded = [array_item(encode(integer_to_binary(I), Item, Gap, Inner)) || {I, Item} <- lists:enumerate(0, Items)],
    wrap($[, Encoded, $], Gap, Indent).

array_item(undefined) -> <<"null">>;
array_item(Text) -> Text.

object(Map, Gap, Indent) ->
    Inner = <<Indent/binary, Gap/binary>>,
    Separator =
        case Gap of
            <<>> -> <<":">>;
            _ -> <<": ">>
        end,
    Members = [
        [quote(Key), Separator, Text]
     || {Key, Value} <- lists:sort(maps:to_list(Map)),
        Text <- [encode(Key, Value, Gap, Inner)],
        Text =/= undefined
    ],
    case Members of
        [] -> <<"{}">>;
        _ -> wrap(${, Members, $}, Gap, Indent)
    end.

wrap(Open, Parts, Close, <<>>, _Indent) ->
    [Open, lists:join($,, Parts), Close];
wrap(Open, Parts, Close, Gap, Indent) ->
    Inner = <<"\n", Indent/binary, Gap/binary>>,
    [Open, Inner, lists:join([$,, Inner], Parts), $\n, Indent, Close].

%% QuoteJSONString: escapes `"`, `\`, and the control characters.
quote(S) ->
    [$", escape(S), $"].

escape(S) ->
    case needs_escape(S) of
        false -> S;
        true -> [escape_char(C) || <<C>> <= S]
    end.

needs_escape(<<C, _/binary>>) when C < 16#20; C =:= $"; C =:= $\\ -> true;
needs_escape(<<_, Rest/binary>>) -> needs_escape(Rest);
needs_escape(<<>>) -> false.

escape_char($") -> <<"\\\"">>;
escape_char($\\) -> <<"\\\\">>;
escape_char($\b) -> <<"\\b">>;
escape_char($\f) -> <<"\\f">>;
escape_char($\n) -> <<"\\n">>;
escape_char($\r) -> <<"\\r">>;
escape_char($\t) -> <<"\\t">>;
escape_char(C) when C < 16#20 -> io_lib:format("\\u~4.16.0b", [C]);
escape_char(C) -> C.

%%% parse

%% `JSON.parse(text)`. Duplicate keys keep the last value, as in
%% JavaScript, and numbers out of the double range become infinities.
-spec parse(list()) -> term().
parse(Args) ->
    case bouy_rt:arg(2, Args) of
        undefined -> ok;
        _ -> bouy_error:throw(<<"TypeError">>, <<"JSON.parse supports no reviver">>)
    end,
    Text = bouy_rt:to_string(bouy_rt:arg(1, Args)),
    try json:decode(Text, ok, decoders()) of
        {Value, ok, Rest} -> trailing(Text, Value, Rest)
    catch
        error:Reason -> syntax_error(Text, Reason)
    end.

decoders() ->
    #{
        object_finish => fun(Members, Acc) -> {maps:from_list(lists:reverse(Members)), Acc} end,
        float => fun bouy_number:from_string/1,
        integer => fun integer/1
    }.

integer(<<"-", Digits/binary>>) -> bouy_rt:negate(bouy_number:from_integer_text(Digits, 10));
integer(Digits) -> bouy_number:from_integer_text(Digits, 10).

trailing(Text, Value, <<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trailing(Text, Value, Rest);
trailing(_Text, Value, <<>>) ->
    Value;
trailing(Text, _Value, <<C, _/binary>>) ->
    syntax_error(Text, {invalid_byte, C}).

-spec syntax_error(binary(), term()) -> no_return().
syntax_error(<<"undefined">>, _) ->
    bouy_error:throw(<<"SyntaxError">>, <<"\"undefined\" is not valid JSON">>);
syntax_error(_Text, unexpected_end) ->
    bouy_error:throw(<<"SyntaxError">>, <<"Unexpected end of JSON input">>);
syntax_error(Text, {invalid_byte, Byte}) ->
    unexpected_token(Text, <<Byte>>);
syntax_error(Text, {unexpected_sequence, Sequence}) ->
    unexpected_token(Text, Sequence);
syntax_error(Text, _) ->
    unexpected_token(Text, Text).

-spec unexpected_token(binary(), binary()) -> no_return().
unexpected_token(Text, Token) ->
    bouy_error:throw(<<"SyntaxError">>, <<"Unexpected token '", Token/binary, "', \"", Text/binary, "\" is not valid JSON">>).
