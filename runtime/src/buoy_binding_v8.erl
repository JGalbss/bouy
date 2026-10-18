%% internalBinding('v8') (src/node_v8.cc): the heap statistics, the flags, and
%% the profilers of node:v8, mapped to BEAM. The JavaScript heap of a realm is
%% its process: its young heap is V8's new space, its old heap the old space,
%% its off-heap binaries the large object space, and the loaded code the code
%% space. The limit is BUOY_MAX_MEMORY (buoy_guard), and a collection is a
%% mark and sweep of buoy_heap.
-module(buoy_binding_v8).

-export([binding/0, version_tag/0]).

%% The fields of heapStatisticsBuffer, heapSpaceStatisticsBuffer, and
%% heapCodeStatisticsBuffer, in the order of node_v8.cc.
-define(HEAP_FIELDS, [<<"kTotalHeapSizeIndex">>, <<"kTotalHeapSizeExecutableIndex">>, <<"kTotalPhysicalSizeIndex">>,
                      <<"kTotalAvailableSize">>, <<"kUsedHeapSizeIndex">>, <<"kHeapSizeLimitIndex">>,
                      <<"kMallocedMemoryIndex">>, <<"kPeakMallocedMemoryIndex">>, <<"kDoesZapGarbageIndex">>,
                      <<"kNumberOfNativeContextsIndex">>, <<"kNumberOfDetachedContextsIndex">>,
                      <<"kTotalGlobalHandlesSizeIndex">>, <<"kUsedGlobalHandlesSizeIndex">>, <<"kExternalMemoryIndex">>]).
-define(SPACE_FIELDS, [<<"kSpaceSizeIndex">>, <<"kSpaceUsedSizeIndex">>, <<"kSpaceAvailableSizeIndex">>,
                       <<"kPhysicalSpaceSizeIndex">>]).
-define(CODE_FIELDS, [<<"kCodeAndMetadataSizeIndex">>, <<"kBytecodeAndMetadataSizeIndex">>,
                      <<"kExternalScriptSourceSizeIndex">>, <<"kCPUProfilerMetaDataSizeIndex">>]).
-define(SPACES, [<<"read_only_space">>, <<"new_space">>, <<"old_space">>, <<"code_space">>, <<"shared_space">>,
                 <<"trusted_space">>, <<"shared_trusted_space">>, <<"new_large_object_space">>,
                 <<"large_object_space">>, <<"code_large_object_space">>, <<"shared_large_object_space">>,
                 <<"shared_trusted_large_object_space">>, <<"trusted_large_object_space">>]).
-define(FLAGS, {?MODULE, flags}).
-define(PEAK, {?MODULE, peak}).
-define(PROFILES, {?MODULE, profiles}).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Heap = buoy_node:typed_array(<<"Float64Array">>, length(?HEAP_FIELDS)),
    Space = buoy_node:typed_array(<<"Float64Array">>, length(?SPACE_FIELDS)),
    Code = buoy_node:typed_array(<<"Float64Array">>, length(?CODE_FIELDS)),
    Profiler = buoy_node:constructor(<<"GCProfiler">>, 0, fun(_, _) -> undefined end),
    ProfilerProto = buoy_heap:get(Profiler, <<"prototype">>),
    [buoy_heap:define(ProfilerProto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- [{<<"start">>, fun(This, _) -> gc_profile_start(This) end},
                        {<<"stop">>, fun(This, _) -> gc_profile_stop(This) end}]],
    buoy_node:object(
        indexes(?HEAP_FIELDS) ++ indexes(?SPACE_FIELDS) ++ indexes(?CODE_FIELDS) ++ [
        {<<"heapStatisticsBuffer">>, Heap},
        {<<"heapSpaceStatisticsBuffer">>, Space},
        {<<"heapCodeStatisticsBuffer">>, Code},
        {<<"kHeapSpaces">>, buoy_heap:new_array(?SPACES)},
        {<<"detailLevel">>, buoy_node:object([{<<"DETAILED">>, 1}, {<<"BRIEF">>, 0}])},
        {<<"updateHeapStatisticsBuffer">>, F(<<"updateHeapStatisticsBuffer">>, 0, fun(_, _) -> fill(Heap, heap_statistics()) end)},
        {<<"updateHeapSpaceStatisticsBuffer">>, F(<<"updateHeapSpaceStatisticsBuffer">>, 1, fun(_, Args) ->
            fill(Space, space_statistics(lists:nth(trunc(A(1, Args)) + 1, ?SPACES)))
        end)},
        {<<"updateHeapCodeStatisticsBuffer">>, F(<<"updateHeapCodeStatisticsBuffer">>, 0, fun(_, _) ->
            fill(Code, [erlang:memory(code), 0, 0, 0])
        end)},
        {<<"getTotalAllocatedBytes">>, F(<<"getTotalAllocatedBytes">>, 0, fun(_, _) -> total_allocated() end)},
        {<<"getCppHeapStatistics">>, F(<<"getCppHeapStatistics">>, 1, fun(_, _) -> cpp_heap_statistics() end)},
        {<<"cachedDataVersionTag">>, F(<<"cachedDataVersionTag">>, 0, fun(_, _) -> version_tag() end)},
        {<<"setFlagsFromString">>, F(<<"setFlagsFromString">>, 1, fun(_, Args) ->
            erlang:put(?FLAGS, [buoy_ref:to_string(A(1, Args)) | flags()]),
            undefined
        end)},
        {<<"setHeapSnapshotNearHeapLimit">>, F(<<"setHeapSnapshotNearHeapLimit">>, 1, fun(_, _) -> undefined end)},
        {<<"isStringOneByteRepresentation">>, F(<<"isStringOneByteRepresentation">>, 1, fun(_, Args) ->
            lists:all(fun(U) -> U < 256 end, buoy_ref_string:units(A(1, Args)))
        end)},
        {<<"getHashSeed">>, F(<<"getHashSeed">>, 0, fun(_, _) -> erlang:phash2(node()) end)},
        {<<"startCpuProfile">>, F(<<"startCpuProfile">>, 0, fun(_, _) -> cpu_profile_start() end)},
        {<<"stopCpuProfile">>, F(<<"stopCpuProfile">>, 1, fun(_, Args) -> cpu_profile_stop(A(1, Args)) end)},
        {<<"GCProfiler">>, Profiler}]).

indexes(Fields) -> lists:zip(Fields, lists:seq(0, length(Fields) - 1)).

fill(Array, Values) ->
    [buoy_heap:set(Array, I, V) || {I, V} <- lists:enumerate(0, Values)],
    undefined.

flags() ->
    case erlang:get(?FLAGS) of
        undefined -> [];
        Flags -> Flags
    end.

%% V8 derives the tag of its code cache from its version and its flags.
-spec version_tag() -> non_neg_integer().
version_tag() ->
    erlang:phash2({erlang:system_info(otp_release), erlang:system_info(version), flags()}, 1 bsl 32).

%%% Heap statistics

words(Words) -> Words * erlang:system_info(wordsize).

gc_info() ->
    {garbage_collection_info, Info} = erlang:process_info(self(), garbage_collection_info),
    maps:from_list(Info).

limit() -> buoy_guard:limit(os:getenv("BUOY_MAX_MEMORY", "")).

%% The values of heapStatisticsBuffer, in the order of ?HEAP_FIELDS.
heap_statistics() ->
    {memory, Process} = erlang:process_info(self(), memory),
    #{heap_size := Young, old_heap_size := Old, heap_block_size := YoungBlock,
      old_heap_block_size := OldBlock} = gc_info(),
    Used = words(Young + Old),
    Total = words(YoungBlock + OldBlock),
    System = erlang:memory(system),
    Peak = max(System, case erlang:get(?PEAK) of undefined -> 0; P -> P end),
    erlang:put(?PEAK, Peak),
    Contexts = case erlang:get('$buoy_realms') of undefined -> 1; N -> N + 1 end,
    [Total, 0, Process, max(0, limit() - erlang:memory(total)), Used, limit(), System, Peak, 0, Contexts, 0,
     0, 0, erlang:memory(binary)].

%% The values of heapSpaceStatisticsBuffer for one space.
space_statistics(Name) ->
    {Size, UsedSize} = case Name of
        <<"new_space">> -> #{heap_block_size := S, heap_size := U} = gc_info(), {words(S), words(U)};
        <<"old_space">> -> #{old_heap_block_size := S, old_heap_size := U} = gc_info(), {words(S), words(U)};
        <<"large_object_space">> -> {binary, B} = erlang:process_info(self(), binary), Bytes = binaries(B), {Bytes, Bytes};
        <<"code_space">> -> C = erlang:memory(code), {C, C};
        _ -> {0, 0}
    end,
    [Size, UsedSize, Size - UsedSize, Size].

binaries(List) -> lists:sum([Size || {_, Size, _} <- List]).

%% The bytes that the VM has allocated since it started: what its collections
%% reclaimed, and what it holds now.
total_allocated() ->
    {_, Reclaimed, _} = erlang:statistics(garbage_collection),
    words(Reclaimed) + erlang:memory(total).

%% Buoy has no cppgc heap: the statistics of an empty one.
cpp_heap_statistics() ->
    buoy_node:object([{<<"committed_size_bytes">>, 0}, {<<"resident_size_bytes">>, 0}, {<<"used_size_bytes">>, 0},
                      {<<"space_statistics">>, buoy_heap:new_array([])},
                      {<<"type_names">>, buoy_heap:new_array([])}]).

%%% The GC profiler of node:v8: the collections of buoy_heap while it runs

gc_profile_start(This) ->
    buoy_heap:private_put(This, {'#', ?MODULE, <<"gc">>}, {erlang:system_time(millisecond), buoy_heap:gc_stats(), heap_statistics()}),
    undefined.

gc_profile_stop(This) ->
    case buoy_heap:private_find(This, {'#', ?MODULE, <<"gc">>}) of
        {ok, {Start, Before, BeforeHeap}} ->
            After = buoy_heap:gc_stats(),
            Runs = maps:get(runs, After) - maps:get(runs, Before),
            Statistics = case Runs > 0 of
                true -> [#{gcType => <<"MarkSweepCompact">>, cost => maps:get(total_us, After) - maps:get(total_us, Before),
                           beforeGC => gc_heap(BeforeHeap), afterGC => gc_heap(heap_statistics())}];
                false -> []
            end,
            buoy_node:string(json:encode(#{version => 1, startTime => Start, endTime => erlang:system_time(millisecond),
                                           statistics => Statistics}));
        error ->
            undefined
    end.

gc_heap(Values) ->
    Keys = [totalHeapSize, totalHeapSizeExecutable, totalPhysicalSize, totalAvailableSize, usedHeapSize, heapSizeLimit,
            mallocedMemory, peakMallocedMemory, doesZapGarbage, numberOfNativeContexts, numberOfDetachedContexts,
            totalGlobalHandlesSize, usedGlobalHandlesSize, externalMemory],
    Heap = maps:without([doesZapGarbage, numberOfNativeContexts, numberOfDetachedContexts], maps:from_list(lists:zip(Keys, Values))),
    #{heapStatistics => Heap,
      heapSpaceStatistics => [begin
                                  [Size, Used, Available, Physical] = space_statistics(Name),
                                  #{spaceName => Name, spaceSize => Size, spaceUsedSize => Used,
                                    spaceAvailableSize => Available, physicalSpaceSize => Physical}
                              end || Name <- ?SPACES]}.

%%% The CPU profiler of v8.startCpuProfile: a process samples the stack of the
%%% realm every millisecond, and the profile is V8's .cpuprofile JSON.

cpu_profile_start() ->
    Realm = self(),
    Sampler = spawn_link(fun() -> sample(Realm, erlang:monotonic_time(microsecond), []) end),
    Id = erlang:unique_integer([positive]),
    Profiles = case erlang:get(?PROFILES) of undefined -> #{}; P -> P end,
    erlang:put(?PROFILES, Profiles#{Id => Sampler}),
    Id.

cpu_profile_stop(Id) ->
    Profiles = case erlang:get(?PROFILES) of undefined -> #{}; P -> P end,
    case maps:take(Id, Profiles) of
        {Sampler, Rest} ->
            erlang:put(?PROFILES, Rest),
            Ref = erlang:monitor(process, Sampler),
            Sampler ! {stop, self(), Ref},
            receive
                {Ref, Start, Samples} ->
                    erlang:demonitor(Ref, [flush]),
                    unlink(Sampler),
                    buoy_node:string(json:encode(profile(Start, lists:reverse(Samples))))
            end;
        error ->
            undefined
    end.

sample(Realm, Start, Samples) ->
    receive
        {stop, From, Ref} -> From ! {Ref, Start, Samples}
    after 1 ->
        Stack = case erlang:process_info(Realm, current_stacktrace) of
            {current_stacktrace, Frames} -> [{M, F} || {M, F, _, _} <- lists:reverse(Frames)];
            undefined -> []
        end,
        sample(Realm, Start, [{erlang:monotonic_time(microsecond), Stack} | Samples])
    end.

%% The tree of the sampled stacks: node 1 is the root, and each sample counts
%% a hit on the node of its innermost frame.
profile(Start, Samples) ->
    {Nodes, Hits, _} = lists:foldl(fun({_, Stack}, {Tree, Ids, Next}) ->
        {Leaf, Tree1, Next1} = insert(Stack, 1, Tree, Next),
        {Tree1, [Leaf | Ids], Next1}
    end, {#{1 => {<<"(root)">>, <<>>, []}}, [], 2}, Samples),
    Counts = lists:foldl(fun(Id, Acc) -> maps:update_with(Id, fun(C) -> C + 1 end, 1, Acc) end, #{}, Hits),
    Times = [T || {T, _} <- Samples],
    Deltas = [B - A || {A, B} <- lists:zip(lists:sublist([Start | Times], length(Times)), Times)],
    End = lists:last([Start | Times]),
    #{nodes => [#{id => Id, hitCount => maps:get(Id, Counts, 0), children => lists:reverse(Children),
                  callFrame => #{functionName => Name, scriptId => <<"0">>, url => Url, lineNumber => -1, columnNumber => -1}}
                || {Id, {Name, Url, Children}} <- lists:sort(maps:to_list(Nodes))],
      startTime => Start, endTime => End, samples => lists:reverse(Hits), timeDeltas => Deltas}.

insert([], Id, Tree, Next) ->
    {Id, Tree, Next};
insert([{M, F} | Rest], Parent, Tree, Next) ->
    {Name, Url, Children} = maps:get(Parent, Tree),
    Key = {atom_to_binary(F), atom_to_binary(M)},
    case [C || C <- Children, element(1, maps:get(C, Tree)) =:= element(1, Key), element(2, maps:get(C, Tree)) =:= element(2, Key)] of
        [Child | _] ->
            insert(Rest, Child, Tree, Next);
        [] ->
            Tree1 = Tree#{Parent => {Name, Url, [Next | Children]}, Next => {element(1, Key), element(2, Key), []}},
            insert(Rest, Next, Tree1, Next + 1)
    end.
