%% The histogram of perf_hooks (src/histogram.cc): HdrHistogram, as
%% deps/histogram of Node implements it, so min, max, mean, and the
%% percentiles report the same equivalent values. A value falls into the
%% bucket of its magnitude and the sub-bucket of its first significant
%% figures; the counts are a map from the index of a sub-bucket, so a
%% histogram holds only the buckets that it recorded.
-module(buoy_node_histogram).

-export([new/3, record/2, record_delta/1, add/2, reset/1]).
-export([count/1, exceeds/1, min/1, max/1, mean/1, stddev/1, percentile/2, percentiles/1]).

-define(INT64_MAX, 9223372036854775807).

-type histogram() :: #{atom() => term()}.
-export_type([histogram/0]).

%% hdr_init(lowest, highest, figures): lowest >= 1, highest >= 2 * lowest, and
%% 1 to 5 significant figures, as lib validates them.
-spec new(pos_integer(), pos_integer(), 1..5) -> histogram().
new(Lowest, Highest, Figures) ->
    SubBucketCountMagnitude = ceil_log2(2 * pow10(Figures)),
    HalfMagnitude = max(SubBucketCountMagnitude, 1) - 1,
    UnitMagnitude = floor_log2(Lowest),
    SubBucketCount = 1 bsl (HalfMagnitude + 1),
    BucketCount = buckets_needed(Highest, SubBucketCount, UnitMagnitude, SubBucketCount bsl UnitMagnitude, 1),
    #{lowest => Lowest, highest => Highest, figures => Figures,
      unit => UnitMagnitude, half_magnitude => HalfMagnitude,
      sub_bucket_count => SubBucketCount, half_count => SubBucketCount div 2,
      mask => (SubBucketCount - 1) bsl UnitMagnitude,
      counts_len => (BucketCount + 1) * (SubBucketCount div 2),
      counts => #{}, total => 0, min_value => ?INT64_MAX, max_value => 0,
      count => 0, exceeds => 0, prev => 0}.

buckets_needed(Value, _SubBucketCount, _Unit, Smallest, Needed) when Smallest > Value -> Needed;
buckets_needed(_Value, _SubBucketCount, _Unit, Smallest, Needed) when Smallest > ?INT64_MAX div 2 -> Needed + 1;
buckets_needed(Value, SubBucketCount, Unit, Smallest, Needed) ->
    buckets_needed(Value, SubBucketCount, Unit, Smallest bsl 1, Needed + 1).

%% Histogram::Record: a value below 0 or above the highest one counts as
%% exceeding.
-spec record(histogram(), integer()) -> histogram().
record(H, Value) ->
    case record_values(H, Value, 1) of
        {ok, H1} -> H1#{count := maps:get(count, H1) + 1};
        error -> H#{exceeds := maps:get(exceeds, H) + 1}
    end.

record_values(#{highest := Highest}, Value, _N) when Value < 0; Value > Highest ->
    error;
record_values(#{counts := Counts, counts_len := Len, total := Total, min_value := Min, max_value := Max} = H, Value, N) ->
    case counts_index_for(H, Value) of
        Index when Index < 0; Index >= Len ->
            error;
        Index ->
            {ok, H#{counts := Counts#{Index => maps:get(Index, Counts, 0) + N}, total := Total + N,
                    min_value := case Value < Min andalso Value =/= 0 of true -> Value; false -> Min end,
                    max_value := erlang:max(Value, Max)}}
    end.

%% Histogram::RecordDelta: the nanoseconds since the last call, from the
%% second call on.
-spec record_delta(histogram()) -> histogram().
record_delta(#{prev := Prev} = H) ->
    Now = erlang:monotonic_time(nanosecond),
    H1 = case Prev > 0 andalso Now - Prev > 0 of
        true -> record(H, Now - Prev);
        false -> H
    end,
    H1#{prev := Now}.

%% Histogram::Add: the counts of Other that fit, as hdr_add.
-spec add(histogram(), histogram()) -> histogram().
add(H, #{count := Count, exceeds := Exceeds, prev := Prev} = Other) ->
    Added = lists:foldl(fun({Index, N}, Acc) ->
                                case record_values(Acc, value_at_index(Other, Index), N) of
                                    {ok, Acc1} -> Acc1;
                                    error -> Acc
                                end
                        end, H, sorted(Other)),
    Added#{count := maps:get(count, Added) + Count, exceeds := maps:get(exceeds, Added) + Exceeds,
           prev := erlang:max(Prev, maps:get(prev, Added))}.

-spec reset(histogram()) -> histogram().
reset(#{lowest := Lowest, highest := Highest, figures := Figures}) -> new(Lowest, Highest, Figures).

-spec count(histogram()) -> non_neg_integer().
count(#{count := Count}) -> Count.

-spec exceeds(histogram()) -> non_neg_integer().
exceeds(#{exceeds := Exceeds}) -> Exceeds.

%% hdr_min: 0 when 0 was recorded, else the lowest equivalent value of the
%% least value, or INT64_MAX when the histogram is empty.
-spec min(histogram()) -> integer().
min(#{counts := #{0 := N}}) when N > 0 -> 0;
min(#{min_value := ?INT64_MAX}) -> ?INT64_MAX;
min(#{min_value := Min} = H) -> lowest_equivalent(H, Min).

-spec max(histogram()) -> integer().
max(#{max_value := 0}) -> 0;
max(#{max_value := Max} = H) -> highest_equivalent(H, Max).

%% hdr_mean: the mean of the median equivalent values, NaN when empty.
-spec mean(histogram()) -> float() | 'NaN'.
mean(#{total := 0}) -> 'NaN';
mean(#{total := Total} = H) ->
    lists:sum([N * median_equivalent(H, value_at_index(H, I)) || {I, N} <- sorted(H)]) / Total.

-spec stddev(histogram()) -> float() | 'NaN'.
stddev(#{total := 0}) -> 'NaN';
stddev(#{total := Total} = H) ->
    Mean = mean(H),
    Deviation = fun(I) -> D = median_equivalent(H, value_at_index(H, I)) - Mean, D * D end,
    Sum = lists:foldl(fun({I, N}, Acc) -> Acc + Deviation(I) * N end, 0.0, sorted(H)),
    math:sqrt(Sum / Total).

%% hdr_value_at_percentile
-spec percentile(histogram(), float()) -> integer().
percentile(#{total := Total} = H, Percentile) ->
    Requested = erlang:min(Percentile, 100.0),
    CountAt = erlang:max(trunc(Requested / 100 * Total + 0.5), 1),
    Value = value_up_to_count(H, sorted(H), CountAt, 0),
    case Percentile == 0 of
        true -> lowest_equivalent(H, Value);
        false -> highest_equivalent(H, Value)
    end.

value_up_to_count(_H, [], _CountAt, _Seen) -> 0;
value_up_to_count(H, [{I, N} | Rest], CountAt, Seen) ->
    case Seen + N >= CountAt of
        true -> value_at_index(H, I);
        false -> value_up_to_count(H, Rest, CountAt, Seen + N)
    end.

%% The percentile iterator of hdr_iter_percentile_init with one tick per
%% half distance: [{Percentile, Value}], as Histogram::Percentiles reports
%% them, with the value at the index where each percentile is reached.
-spec percentiles(histogram()) -> [{float(), integer()}].
percentiles(#{total := Total} = H) ->
    Entries = [{value_at_index(H, I), N} || {I, N} <- sorted(H)],
    lists:reverse(iterate(Entries, Total, 0, 0, 0.0, 0.0, [])).

%% One step of percentile_iter_next: the iteration ends after it reported
%% 100 once all counts are seen; otherwise it reports the next percentile
%% that the cumulative count reaches, moving over the entries as needed.
iterate(_Entries, Total, Value, Cumulative, _To, _Last, Acc) when Cumulative >= Total ->
    [{100.0, Value} | Acc];
iterate([{V, N} | Rest], Total, _Value, 0, To, Last, Acc) ->
    scan(Rest, Total, V, N, To, Last, Acc);
iterate(Entries, Total, Value, Cumulative, To, Last, Acc) ->
    scan(Entries, Total, Value, Cumulative, To, Last, Acc).

scan(Entries, Total, Value, Cumulative, To, Last, Acc) ->
    case To =< 100.0 * Cumulative / Total of
        true ->
            Next = To + 100.0 / math:pow(2, trunc(math:log(100 / (100.0 - To)) / math:log(2)) + 1),
            iterate(Entries, Total, Value, Cumulative, Next, To, [{To, Value} | Acc]);
        false ->
            case Entries of
                [{V, N} | Rest] when Cumulative < Total -> scan(Rest, Total, V, Cumulative + N, To, Last, Acc);
                _ -> iterate([], Total, Value, Total, To, Last, [{Last, Value} | Acc])
            end
    end.

sorted(#{counts := Counts}) -> lists:sort(maps:to_list(Counts)).

%%% The index arithmetic of HdrHistogram

counts_index_for(H, Value) ->
    Bucket = bucket_index(H, Value),
    counts_index(H, Bucket, sub_bucket_index(H, Value, Bucket)).

bucket_index(#{mask := Mask, unit := Unit, half_magnitude := Half}, Value) ->
    bit_length(Value bor Mask) - Unit - (Half + 1).

sub_bucket_index(#{unit := Unit}, Value, Bucket) -> Value bsr (Bucket + Unit).

counts_index(#{half_magnitude := Half, half_count := HalfCount}, Bucket, SubBucket) ->
    ((Bucket + 1) bsl Half) + SubBucket - HalfCount.

value_at_index(#{half_magnitude := Half, half_count := HalfCount, unit := Unit}, Index) ->
    Bucket = (Index bsr Half) - 1,
    SubBucket = (Index band (HalfCount - 1)) + HalfCount,
    case Bucket < 0 of
        true -> (SubBucket - HalfCount) bsl Unit;
        false -> SubBucket bsl (Bucket + Unit)
    end.

lowest_equivalent(#{unit := Unit} = H, Value) ->
    Bucket = bucket_index(H, Value),
    sub_bucket_index(H, Value, Bucket) bsl (Bucket + Unit).

range_size(#{unit := Unit, sub_bucket_count := SubBucketCount} = H, Value) ->
    Bucket = bucket_index(H, Value),
    Adjusted = case sub_bucket_index(H, Value, Bucket) >= SubBucketCount of
        true -> Bucket + 1;
        false -> Bucket
    end,
    1 bsl (Unit + Adjusted).

highest_equivalent(H, Value) -> lowest_equivalent(H, Value) + range_size(H, Value) - 1.

median_equivalent(H, Value) -> lowest_equivalent(H, Value) + (range_size(H, Value) bsr 1).

bit_length(0) -> 0;
bit_length(N) -> 1 + bit_length(N bsr 1).

pow10(N) -> trunc(math:pow(10, N)).

ceil_log2(N) -> bit_length(N - 1).

floor_log2(N) -> bit_length(N) - 1.
