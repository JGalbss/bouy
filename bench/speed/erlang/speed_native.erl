-module(speed_native).

%% The Erlang side of the native tier. `nbody/1`, `richards/1`, and `deltablue/1` run in
%% time slices and yield to the scheduler; the `_blocking` versions run to the end in one
%% call. Richards and DeltaBlue return the sum of their runs as a float.
%% The json_ and regex_ functions are native built-ins: JSON with the term representation
%% of json_typed, and regular expressions on the Rust `regex` crate. The VM loads the
%% library from $SPEED_NATIVE_LIB, without the `.so` suffix.
%% Usage: erl -noshell -pa <ebin> -run speed_native main <kernel> [Warmup] [Runs] [Size]
%% Kernels: nbody, richards, deltablue, json, regex.

-export([nbody/1, nbody_blocking/1, richards/1, richards_blocking/1, deltablue/1, main/1]).
-export([json_parse/1, json_stringify/1]).
-export([regex_match/2, regex_captures/3, regex_test/2, regex_replace/3]).
-on_load(load/0).

load() -> erlang:load_nif(os:getenv("SPEED_NATIVE_LIB", "priv/speed_native"), 0).

-spec nbody(non_neg_integer()) -> float().
nbody(_Steps) -> erlang:nif_error(not_loaded).

-spec nbody_blocking(non_neg_integer()) -> float().
nbody_blocking(_Steps) -> erlang:nif_error(not_loaded).

-spec richards(non_neg_integer()) -> float().
richards(_Runs) -> erlang:nif_error(not_loaded).

-spec richards_blocking(non_neg_integer()) -> float().
richards_blocking(_Runs) -> erlang:nif_error(not_loaded).

-spec deltablue(non_neg_integer()) -> float().
deltablue(_Runs) -> erlang:nif_error(not_loaded).

-spec json_parse(binary()) -> term().
json_parse(_Text) -> erlang:nif_error(not_loaded).

-spec json_stringify(term()) -> binary().
json_stringify(_Value) -> erlang:nif_error(not_loaded).

-spec regex_match(binary(), binary()) -> [binary()].
regex_match(_Pattern, _Text) -> erlang:nif_error(not_loaded).

-spec regex_captures(binary(), binary(), [non_neg_integer()]) -> [[binary()]].
regex_captures(_Pattern, _Text, _Groups) -> erlang:nif_error(not_loaded).

-spec regex_test(binary(), binary()) -> boolean().
regex_test(_Pattern, _Text) -> erlang:nif_error(not_loaded).

-spec regex_replace(binary(), binary(), binary()) -> binary().
regex_replace(_Pattern, _Text, _Replacement) -> erlang:nif_error(not_loaded).

-spec main([string()]) -> no_return().
main(["nbody" | Args]) ->
    speed_harness:bench(<<"nbody">>, 250000, fun nbody/1, Args);
main(["richards" | Args]) ->
    speed_harness:bench(<<"richards">>, 100, fun richards/1, Args);
main(["deltablue" | Args]) ->
    speed_harness:bench(<<"deltablue">>, 100, fun deltablue/1, Args);
main(["regex" | Args]) ->
    Text = regex_typed:text(),
    speed_harness:bench(<<"regex">>, 1, fun(Size) -> regex(Size, Text, 0) end, Args);
main(["json" | Args]) ->
    Document = json_typed:document(),
    speed_harness:bench(<<"json">>, 4, fun(Size) -> json(Size, Document, 0) end, Args).

json(0, _Document, Check) ->
    Check;
json(Size, Document, Check) ->
    Value = json_parse(Document),
    Text = json_stringify(Value),
    Text =:= Document orelse error(round_trip_changed_the_text),
    json(Size - 1, Document, Check + byte_size(Text) + length(Value)).

regex(0, _Text, Check) ->
    Check;
regex(Size, Text, Check) ->
    Emails = regex_match(<<"[\\w.+-]+@[\\w-]+\\.[\\w.]+">>, Text),
    Dates = regex_captures(<<"(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):">>, Text, [3, 4]),
    DateSum = lists:sum([binary_to_integer(Day) + binary_to_integer(Hour) || [Day, Hour] <- Dates]),
    Errors = length([
        Line
     || Line <- binary:split(Text, <<"\n">>, [global]), regex_test(<<"status=5\\d\\d">>, Line)
    ]),
    Replaced = regex_replace(<<"\\d+">>, Text, <<"#">>),
    regex(Size - 1, Text, Check + length(Emails) + DateSum + Errors + byte_size(Replaced)).
