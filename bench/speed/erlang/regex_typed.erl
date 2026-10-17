-module(regex_typed).

%% Regex on OTP's `re`, which runs PCRE2 in C. The four literals compile once, as V8
%% caches the code of a regex literal. Without the unicode option, \w and \d match the
%% ASCII classes, as they do in JavaScript without the u flag.

-export([main/1, text/0]).

-spec main([string()]) -> no_return().
main(Args) ->
    Text = text(),
    {ok, Email} = re:compile(<<"[\\w.+-]+@[\\w-]+\\.[\\w.]+">>),
    {ok, Date} = re:compile(<<"(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):">>),
    {ok, Status} = re:compile(<<"status=5\\d\\d">>),
    {ok, Digits} = re:compile(<<"\\d+">>),
    Patterns = {Email, Date, Status, Digits},
    speed_harness:bench(<<"regex">>, 1, fun(Size) -> iteration(Size, Text, Patterns, 0) end, Args).

iteration(0, _Text, _Patterns, Check) ->
    Check;
iteration(Size, Text, Patterns, Check) ->
    iteration(Size - 1, Text, Patterns, Check + scan(Text, Patterns)).

scan(Text, {Email, Date, Status, Digits}) ->
    {match, Emails} = re:run(Text, Email, [global, {capture, first, index}]),
    {match, Dates} = re:run(Text, Date, [global, {capture, [3, 4], binary}]),
    DateSum = lists:sum([binary_to_integer(Day) + binary_to_integer(Hour) || [Day, Hour] <- Dates]),
    Errors = length([
        Line
     || Line <- binary:split(Text, <<"\n">>, [global]), re:run(Line, Status, [{capture, none}]) =:= match
    ]),
    Replaced = re:replace(Text, Digits, <<"#">>, [global, {return, binary}]),
    length(Emails) + DateSum + Errors + byte_size(Replaced).

pad(N) when N < 10 -> <<"0", (integer_to_binary(N))/binary>>;
pad(N) -> integer_to_binary(N).

level(I) -> element(I rem 4 + 1, {<<"INFO">>, <<"WARN">>, <<"ERROR">>, <<"DEBUG">>}).

status(I) -> element(I rem 4 + 1, {<<"200">>, <<"201">>, <<"404">>, <<"500">>}).

line(I) ->
    N = fun integer_to_binary/1,
    [
        <<"2026-10-">>, pad(I rem 28 + 1), <<"T">>, pad(I rem 24), <<":">>, pad(I rem 60), <<":">>,
        pad((I * 7) rem 60), <<"Z ">>, level(I), <<" user=user">>, N(I), <<"@example.com ip=10.">>,
        N(I rem 256), <<".">>, N((I bsr 8) rem 256), <<".">>, N(I rem 7), <<" path=/api/v1/items/">>,
        N(I rem 1000), <<" status=">>, status(I), <<" ms=">>, N(I rem 250)
    ].

text() -> iolist_to_binary(lists:join(<<"\n">>, [line(I) || I <- lists:seq(0, 9999)])).
