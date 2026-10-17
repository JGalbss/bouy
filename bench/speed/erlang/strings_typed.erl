-module(strings_typed).

%% Strings as a typed compilation: a string that holds only one-byte characters is a
%% binary, as V8 keeps one-byte strings. `+=` in a loop is a binary append, which BEAM
%% does in place while the binary has one owner. split is binary:split, parseInt is
%% binary_to_integer, indexOf is binary:match, and toUpperCase takes the ASCII path.

-export([main/1]).

-define(ROWS, 100000).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"strings">>, 1, fun(Size) -> iteration(Size, 0) end, Args).

iteration(0, Check) ->
    Check;
iteration(Size, Check) ->
    Text = build(0, <<>>),
    iteration(Size - 1, Check + byte_size(Text) + scan(Text)).

tag(0) -> <<"alpha">>;
tag(1) -> <<"beta">>;
tag(2) -> <<"gamma">>;
tag(3) -> <<"delta">>.

build(?ROWS, Text) ->
    Text;
build(I, Text) ->
    Index = integer_to_binary(I),
    build(I + 1, <<Text/binary, Index/binary, ",item-", Index/binary, ",",
        (integer_to_binary((I * 7) rem 1000))/binary, ",", (tag(I rem 4))/binary, "\n">>).

scan(Text) ->
    {Total, Upper} = lists:foldl(fun scan_line/2, {0, []}, binary:split(Text, <<"\n">>, [global])),
    Total + iolist_size(lists:join(<<";">>, lists:reverse(Upper))).

scan_line(<<>>, Acc) ->
    Acc;
scan_line(Line, {Total, Upper}) ->
    [_, Name, Number, Tag] = binary:split(Line, <<",">>, [global]),
    Upper1 =
        case Tag of
            <<"beta">> -> [upper(Name) | Upper];
            _ -> Upper
        end,
    Total1 = Total + binary_to_integer(Number),
    case binary:match(Line, <<"-99">>) of
        nomatch -> {Total1, Upper1};
        {At, _} -> {Total1 + At + min(2, byte_size(Line) - At - 1), Upper1}
    end.

upper(Text) -> <<<<(ascii_upper(C))>> || <<C>> <= Text>>.

ascii_upper(C) when C >= $a, C =< $z -> C - 32;
ascii_upper(C) -> C.
