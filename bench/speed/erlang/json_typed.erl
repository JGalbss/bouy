-module(json_typed).

%% JSON parse and stringify on OTP's `json` module, which is written in Erlang. JavaScript
%% strings are binaries, which is exact for this ASCII document. An object decodes to a
%% list of pairs, so stringify writes the keys in insertion order, as JSON.parse and
%% JSON.stringify must. (Maps would sort the keys.)

-export([main/1, document/0]).

-define(TAGS, [<<"alpha">>, <<"beta">>, <<"gamma">>, <<"delta">>, <<"epsilon">>, <<"zeta">>]).

-spec main([string()]) -> no_return().
main(Args) ->
    Document = document(),
    speed_harness:bench(<<"json">>, 4, fun(Size) -> iteration(Size, Document, 0) end, Args).

iteration(0, _Document, Check) ->
    Check;
iteration(Size, Document, Check) ->
    Value = parse(Document),
    Text = iolist_to_binary(json:encode(Value, fun encode_ordered/2)),
    byte_size(Text) =:= byte_size(Document) orelse error(round_trip_changed_the_text),
    iteration(Size - 1, Document, Check + byte_size(Text) + length(Value)).

parse(Text) ->
    {Value, ok, <<>>} = json:decode(Text, ok, #{
        object_push => fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
        object_finish => fun(Acc, State) -> {{lists:reverse(Acc)}, State} end
    }),
    Value.

encode_ordered({Pairs}, Encode) -> json:encode_key_value_list(Pairs, Encode);
encode_ordered(Other, Encode) -> json:encode_value(Other, Encode).

%% The document of json.ts, built the same way, so its text is byte for byte the text
%% that JSON.stringify gives on Node and Bun.
document() ->
    iolist_to_binary(json:encode([user(I) || I <- lists:seq(0, 2899)], fun encode_ordered/2)).

user(I) ->
    {[
        {<<"id">>, I},
        {<<"name">>, <<"User ", (integer_to_binary(I))/binary>>},
        {<<"email">>, <<"user", (integer_to_binary(I))/binary, "@example.com">>},
        {<<"active">>, I rem 3 =:= 0},
        {<<"score">>, number((I * 37) rem 1000 / 8)},
        {<<"tags">>, [Tag || {Index, Tag} <- lists:enumerate(0, ?TAGS), (I + Index) rem 3 =:= 0]},
        {<<"address">>,
            {[
                {<<"street">>, <<(integer_to_binary(I))/binary, " Main Street">>},
                {<<"city">>, <<"Springfield">>},
                {<<"zip">>, integer_to_binary(10000 + I)}
            ]}},
        {<<"history">>, [
            {[
                {<<"at">>, 1700000000 + I * 60 + K},
                {<<"amount">>, number(((I + K) rem 100) / 4)},
                {<<"currency">>, <<"USD">>}
            ]}
         || K <- [0, 1, 2]
        ]}
    ]}.

%% A JavaScript number that holds an integer prints without a fraction.
number(X) when X == trunc(X) -> trunc(X);
number(X) -> X.
