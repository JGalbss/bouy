%% The `JSON` namespace. `stringify` matches JSON.stringify byte for byte
%% for the values Buoy has; object keys come out in Erlang term order.
%% `parse` uses the OTP `json` module.
-module(buoy_json).

-export(['$member'/1, stringify/1, parse/1]).

-define(FUNCTIONS, [<<"parse">>, <<"stringify">>]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%%% stringify

%% `JSON.stringify(value, replacer, space)`. Buoy supports no replacer
%% function or array. Another replacer is ignored, as in JavaScript, so
%% `xs.map(JSON.stringify)` works.
-spec stringify(list()) -> binary() | undefined.
stringify(Args) ->
    Replacer = buoy_rt:arg(2, Args),
    case is_list(Replacer) orelse buoy_rt:type_of(Replacer) =:= <<"function">> of
        true -> buoy_error:throw(<<"TypeError">>, <<"JSON.stringify supports no replacer: pass null">>);
        false -> ok
    end,
    case encode(<<>>, buoy_rt:arg(1, Args), gap(buoy_rt:arg(3, Args)), <<>>) of
        undefined -> undefined;
        Text -> iolist_to_binary(Text)
    end.

%% The indent: up to 10 spaces, or the first 10 characters of a string.
gap(N) when is_number(N); N =:= 'Infinity' -> binary:copy(<<" ">>, buoy_rt:clamp(N, 0, 10));
gap(S) when is_binary(S) -> buoy_rt:prefix(S, 10);
gap(_) -> <<>>.

%% The JSON text of a value, or undefined for a value that JSON omits.
encode(Key, Value, Gap, Indent) ->
    serialize(to_json(Key, Value), Gap, Indent).

to_json(_Key, {'$date', _} = Date) -> buoy_date:call(<<"toJSON">>, Date, []);
to_json(Key, #{<<"toJSON">> := F}) when is_function(F, 1) -> F([Key]);
to_json(_Key, Value) -> Value.

serialize(null, _, _) -> <<"null">>;
serialize(true, _, _) -> <<"true">>;
serialize(false, _, _) -> <<"false">>;
serialize(N, _, _) when is_number(N) -> buoy_number:to_string(N);
serialize(N, _, _) when N =:= 'NaN'; N =:= 'Infinity'; N =:= '-Infinity' -> <<"null">>;
serialize(S, _, _) when is_binary(S) -> quote(S);
serialize(L, Gap, Indent) when is_list(L) -> array(L, Gap, Indent);
serialize(#{'$error' := _} = Error, Gap, Indent) -> object(buoy_error:fields(Error), Gap, Indent);
serialize(M, Gap, Indent) when is_map(M) -> object(M, Gap, Indent);
serialize(undefined, _, _) -> undefined;
serialize(F, _, _) when is_function(F) -> undefined;
serialize({'$class', _, _}, _, _) -> undefined;
serialize({'$method', _, _}, _, _) -> undefined;
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
     || {Key, Value} <- buoy_object:own_entries(Map),
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
%% JavaScript, and numbers out of the double range become infinities. A
%% reviver function is not supported, and a reviver that is not callable is
%% ignored, as in JavaScript, so `lines.map(JSON.parse)` works.
-spec parse(list()) -> term().
parse(Args) ->
    case buoy_rt:type_of(buoy_rt:arg(2, Args)) of
        <<"function">> -> buoy_error:throw(<<"TypeError">>, <<"JSON.parse supports no reviver">>);
        _ -> ok
    end,
    Text = buoy_rt:to_string(buoy_rt:arg(1, Args)),
    Signed = signed_zeros(Text),
    case attempt(Signed) of
        {ok, Value} -> Value;
        {error, _, _} -> retry(Text, attempt(lone_surrogates(Signed)))
    end.

%% A failed decode decodes the text again, as it came, for the message.
retry(_Text, {ok, Value}) ->
    Value;
retry(Text, {error, _, _}) ->
    case attempt(Text) of
        {ok, Value} -> Value;
        {error, Reason, Position} -> syntax_error(Text, Reason, Position)
    end.

attempt(Text) ->
    try json:decode(Text, ok, decoders()) of
        {Value, ok, Rest} -> trailing(Value, Rest, byte_size(Text) - byte_size(Rest))
    catch
        error:Reason:Stack -> {error, Reason, position(Stack)}
    end.

decoders() ->
    #{
        object_finish => fun(Members, Acc) -> {maps:from_list(lists:reverse(Members)), Acc} end,
        float => fun buoy_number:from_string/1,
        integer => fun integer/1
    }.

integer(<<"-", Digits/binary>>) -> buoy_rt:negate(buoy_number:from_integer_text(Digits, 10));
integer(Digits) -> buoy_number:from_integer_text(Digits, 10).

trailing(Value, <<C, Rest/binary>>, Position) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trailing(Value, Rest, Position + 1);
trailing(Value, <<>>, _Position) ->
    {ok, Value};
trailing(_Value, <<C, _/binary>>, Position) ->
    {error, {invalid_byte, C}, Position}.

%% The byte offset of a decode error, from the error info of OTP json.
position([{json, _, _, Info} | _]) ->
    case proplists:get_value(error_info, Info) of
        #{cause := #{position := Position}} -> Position;
        _ -> undefined
    end;
position(_Stack) ->
    undefined.

%% The number -0 becomes -0.0, because the OTP decoder drops the sign of an
%% integer zero.
signed_zeros(Text) ->
    case re:run(Text, <<"-0(?![.0-9])">>, [{capture, none}]) of
        match -> iolist_to_binary(zeros(Text));
        nomatch -> Text
    end.

zeros(<<$", Rest/binary>>) -> [$" | in_string(Rest)];
zeros(<<"-0", C, Rest/binary>>) when C =/= $., C < $0; C =/= $., C > $9 -> [<<"-0.0">> | zeros(<<C, Rest/binary>>)];
zeros(<<"-0">>) -> [<<"-0.0">>];
zeros(<<C, Rest/binary>>) -> [C | zeros(Rest)];
zeros(<<>>) -> [].

in_string(<<$\\, C, Rest/binary>>) -> [$\\, C | in_string(Rest)];
in_string(<<$", Rest/binary>>) -> [$" | zeros(Rest)];
in_string(<<C, Rest/binary>>) -> [C | in_string(Rest)];
in_string(<<>>) -> [].

%% An escaped surrogate that is not part of a pair becomes U+FFFD, which the
%% OTP decoder rejects and UTF-8 cannot hold, as String.fromCharCode does.
lone_surrogates(Text) ->
    case binary:match(Text, <<"\\u">>) of
        nomatch -> Text;
        _ -> iolist_to_binary(escapes(Text))
    end.

escapes(<<"\\u", High:4/binary, "\\u", Low:4/binary, Rest/binary>> = Text) ->
    case {hex(High), hex(Low)} of
        {H, L} when H >= 16#D800, H =< 16#DBFF, L >= 16#DC00, L =< 16#DFFF ->
            [<<"\\u", High/binary, "\\u", Low/binary>> | escapes(Rest)];
        _ ->
            lone_escape(Text)
    end;
escapes(<<"\\u", _/binary>> = Text) ->
    lone_escape(Text);
escapes(<<$\\, C, Rest/binary>>) ->
    [$\\, C | escapes(Rest)];
escapes(<<C, Rest/binary>>) ->
    [C | escapes(Rest)];
escapes(<<>>) ->
    [].

lone_escape(<<"\\u", Code:4/binary, Rest/binary>>) ->
    case hex(Code) of
        Unit when Unit >= 16#D800, Unit =< 16#DFFF -> [<<"\\ufffd">> | escapes(Rest)];
        _ -> [<<"\\u", Code/binary>> | escapes(Rest)]
    end;
lone_escape(<<$\\, C, Rest/binary>>) ->
    [$\\, C | escapes(Rest)].

hex(Code) ->
    try binary_to_integer(Code, 16) of
        Unit -> Unit
    catch
        error:badarg -> -1
    end.

-spec syntax_error(binary(), term(), non_neg_integer() | undefined) -> no_return().
syntax_error(<<"undefined">>, _, _) ->
    buoy_error:throw(<<"SyntaxError">>, <<"\"undefined\" is not valid JSON">>);
syntax_error(_Text, unexpected_end, _) ->
    buoy_error:throw(<<"SyntaxError">>, <<"Unexpected end of JSON input">>);
syntax_error(Text, {invalid_byte, Byte}, Position) ->
    unexpected_token(Text, character(Text, Position, Byte));
syntax_error(Text, {unexpected_sequence, Sequence}, _) ->
    unexpected_token(Text, Sequence);
syntax_error(Text, _, _) ->
    unexpected_token(Text, Text).

%% The whole character at a byte offset, so a message never holds a part of
%% a UTF-8 sequence.
character(Text, Position, _Byte) when is_integer(Position), Position < byte_size(Text) ->
    case Text of
        <<_:Position/binary, C/utf8, _/binary>> -> <<C/utf8>>;
        _ -> <<16#FFFD/utf8>>
    end;
character(_Text, _Position, Byte) when Byte < 16#80 ->
    <<Byte>>;
character(_Text, _Position, _Byte) ->
    <<16#FFFD/utf8>>.

-spec unexpected_token(binary(), binary()) -> no_return().
unexpected_token(Text, Token) ->
    buoy_error:throw(<<"SyntaxError">>, <<"Unexpected token '", Token/binary, "', \"", Text/binary, "\" is not valid JSON">>).
