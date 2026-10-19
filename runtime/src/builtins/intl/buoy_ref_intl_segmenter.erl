%% Intl.Segmenter (ECMA-402 section 19): an object of the class
%% intl_segmenter whose slots hold the resolved locale and granularity, the
%% Segments objects of its segment method, of the class intl_segments, and
%% their iterators, of the class intl_segment_iterator. The boundaries come
%% from ICU4X's segmenters (buoy_native:intl_segment/3), once per Segments
%% object, as UTF-16 indices.
-module(buoy_ref_intl_segmenter).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.Segmenter.prototype').
-define(SEGMENTS, '%SegmentsPrototype%').
-define(ITERATOR, '%SegmentIteratorPrototype%').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Iterate = buoy_ref_realm:builtin(<<"%SegmentsPrototype%[Symbol.iterator]">>, <<"[Symbol.iterator]">>, 0,
                                     fun(This, _) -> iterator(This) end),
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.Segmenter.prototype">>, [{<<"resolvedOptions">>, 0}, {<<"segment">>, 1}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.Segmenter">>, 4}],
                     none)},
     {?SEGMENTS, record(object, ?OBJECT_PROTO, ?METHODS(<<"%SegmentsPrototype%">>, [{<<"containing">>, 1}])
                        ++ [{?SYM(iterator), Iterate}], none)},
     {?ITERATOR, record(object, ?ITERATOR_PROTO, ?METHODS(<<"%SegmentIteratorPrototype%">>, [{<<"next">>, 0}])
                        ++ [{?SYM(toStringTag), <<"Segmenter String Iterator">>, 4}], none)},
     {{builtin, <<"Intl.Segmenter">>}, ctor_record(<<"Segmenter">>, 0, {'$o', ?PROTO},
                                                   ?METHODS(<<"Intl.Segmenter">>, [{<<"supportedLocalesOf">>, 1}]),
                                                   fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.Segmenter">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.Segmenter requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.Segmenter">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.Segmenter.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    S = slots(This, intl_segmenter, <<"Intl.Segmenter.prototype.resolvedOptions">>),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, S)}, {<<"granularity">>, maps:get(granularity, S)}]);
method(<<"Intl.Segmenter.prototype">>, <<"segment">>, This, Args) ->
    S = slots(This, intl_segmenter, <<"Intl.Segmenter.prototype.segment">>),
    Text = buoy_ref:to_string(arg(1, Args)),
    buoy_heap:new_exotic(intl_segments, buoy_heap:intrinsic(?SEGMENTS), S#{string => Text, boundaries => undefined});
method(<<"%SegmentsPrototype%">>, <<"containing">>, This, Args) ->
    slots(This, intl_segments, <<"%Segments.prototype%.containing">>),
    Length = buoy_ref_string:length_of(maps:get(string, buoy_heap:slots(This))),
    case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(arg(1, Args))) of
        N when is_integer(N), N >= 0, N < Length ->
            {Start, End, WordLike} = segment_at(boundaries(This), N),
            segment_data(buoy_heap:slots(This), Start, End, WordLike);
        _ -> undefined
    end;
method(<<"%SegmentIteratorPrototype%">>, <<"next">>, This, _Args) ->
    S = slots(This, intl_segment_iterator, <<"%SegmentIteratorPrototype%.next">>),
    Position = maps:get(position, S),
    Segments = maps:get(segments, S),
    case Position >= buoy_ref_string:length_of(maps:get(string, buoy_heap:slots(Segments))) of
        true -> buoy_ref_iterator:result(undefined, true);
        false ->
            {Start, End, WordLike} = segment_at(boundaries(Segments), Position),
            buoy_heap:set_slots(This, S#{position => End}),
            buoy_ref_iterator:result(segment_data(buoy_heap:slots(Segments), Start, End, WordLike), false)
    end.

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:get_options_object(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [], [], fun(_, _) -> [] end),
    Granularity = get_option(Options, <<"granularity">>, string, [<<"grapheme">>, <<"word">>, <<"sentence">>], <<"grapheme">>),
    buoy_heap:new_exotic(intl_segmenter, Proto,
                         #{locale => maps:get(locale, Resolved), data_locale => maps:get(data_locale, Resolved),
                           granularity => Granularity}).

slots(This, Class, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= Class orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method ">>, Name, <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%% %SegmentsPrototype%[@@iterator]: CreateSegmentIterator.
iterator(This) ->
    slots(This, intl_segments, <<"%Segments.prototype%[@@iterator]">>),
    buoy_heap:new_exotic(intl_segment_iterator, buoy_heap:intrinsic(?ITERATOR), #{segments => This, position => 0}).

%%% Boundaries

%% The boundaries of a Segments object as a tuple of {Index, IsWordLike},
%% made on first use.
boundaries(Segments) ->
    S = buoy_heap:slots(Segments),
    case maps:get(boundaries, S) of
        undefined ->
            Found = list_to_tuple(buoy_native:intl_segment(binary_to_atom(maps:get(granularity, S)),
                                                           buoy_ref_intl:base_name(maps:get(data_locale, S)),
                                                           buoy_ref_string:wide(maps:get(string, S)))),
            buoy_heap:set_slots(Segments, S#{boundaries => Found}),
            Found;
        Found -> Found
    end.

%% {Start, End, IsWordLike} of the segment that holds the code unit N:
%% FindBoundary before and after N, by binary search.
segment_at(Boundaries, N) ->
    I = search(Boundaries, N, 1, tuple_size(Boundaries)),
    {Start, _} = element(I, Boundaries),
    {End, WordLike} = element(I + 1, Boundaries),
    {Start, End, WordLike}.

%% The largest position I with element I at or before N.
search(_Boundaries, _N, Low, High) when Low >= High -> Low;
search(Boundaries, N, Low, High) ->
    Mid = (Low + High + 1) div 2,
    case element(1, element(Mid, Boundaries)) =< N of
        true -> search(Boundaries, N, Mid, High);
        false -> search(Boundaries, N, Low, Mid - 1)
    end.

%% CreateSegmentDataObject.
segment_data(S, Start, End, WordLike) ->
    String = maps:get(string, S),
    Base = [{<<"segment">>, buoy_ref_string:slice(String, Start, End)}, {<<"index">>, Start}, {<<"input">>, String}],
    buoy_heap:object(?OBJECT_PROTO, case maps:get(granularity, S) of
                                        <<"word">> -> Base ++ [{<<"isWordLike">>, WordLike}];
                                        _ -> Base
                                    end).
