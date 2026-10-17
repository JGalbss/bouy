-module(bouy_guard).

%% Stops a program before it can exhaust the machine's memory (section 1 of the contract).
%%
%% BOUY_MAX_MEMORY sets the limit in bytes, with an optional K, M, G, or T suffix
%% (powers of 1024). The default, 4G, matches the default heap limit of Node on 64-bit
%% machines. Two checks enforce it:
%% - every process gets a max_heap_size of the limit, so one runaway process dies at
%%   its next collection;
%% - a watchdog reads erlang:memory(total), so growth spread over many processes, or in
%%   binaries outside any heap, also stops the VM.
%% Either way the VM prints one line to stderr and halts with status 1.

-export([start/0, limit/1, bytes/1]).

-define(DEFAULT_LIMIT, 4 * 1024 * 1024 * 1024).
-define(INTERVAL_MS, 100).

-spec start() -> ok.
start() ->
    Limit = limit(os:getenv("BOUY_MAX_MEMORY", "")),
    MaxHeap = #{
        size => Limit div erlang:system_info(wordsize),
        kill => true,
        error_logger => false,
        include_shared_binaries => true
    },
    _ = erlang:system_flag(max_heap_size, MaxHeap),
    %% The flag covers only processes spawned from now on, and the calling process runs
    %% the program, so it takes the limit itself.
    _ = process_flag(max_heap_size, MaxHeap),
    Main = self(),
    _ = spawn_opt(fun() -> watch(monitor(process, Main), Limit) end, [{priority, high}]),
    ok.

%% The limit in bytes for a value of BOUY_MAX_MEMORY. An empty or unreadable value gives
%% the default.
-spec limit(string()) -> pos_integer().
limit(Text) ->
    case bytes(Text) of
        {ok, Bytes} -> Bytes;
        error -> ?DEFAULT_LIMIT
    end.

%% A positive number of bytes with an optional K, M, G, or T suffix (powers of 1024),
%% such as "64M", which BOUY_MAX_MEMORY and the maxMemory option of an actor take. It
%% parses by hand: the string module would load unicode_util, a large module, on each
%% start of the VM.
-spec bytes(string()) -> {ok, pos_integer()} | error.
bytes(Text) ->
    case digits(lists:dropwhile(fun is_space/1, Text), 0, 0) of
        {Number, Suffix} when Number > 0 ->
            scale(Number, lists:dropwhile(fun is_space/1, lists:reverse(Suffix)));
        _ ->
            error
    end.

%% The leading digits as a number, and the rest of the text.
digits([Digit | Rest], Number, Count) when Digit >= $0, Digit =< $9 ->
    digits(Rest, Number * 10 + Digit - $0, Count + 1);
digits(Rest, Number, Count) when Count > 0 ->
    {Number, Rest};
digits(_Rest, _Number, _Count) ->
    error.

is_space(Char) -> Char =:= $\s orelse Char =:= $\t orelse Char =:= $\n orelse Char =:= $\r.

%% The suffix without trailing space, reversed: one letter or none.
scale(Number, "") -> {ok, Number};
scale(Number, [Unit]) when Unit =:= $K; Unit =:= $k -> {ok, Number * 1024};
scale(Number, [Unit]) when Unit =:= $M; Unit =:= $m -> {ok, Number * 1024 * 1024};
scale(Number, [Unit]) when Unit =:= $G; Unit =:= $g -> {ok, Number * 1024 * 1024 * 1024};
scale(Number, [Unit]) when Unit =:= $T; Unit =:= $t -> {ok, Number * 1024 * 1024 * 1024 * 1024};
scale(_Number, _Suffix) -> error.

watch(Main, Limit) ->
    receive
        {'DOWN', Main, process, _, killed} -> exceeded(Limit);
        {'DOWN', Main, process, _, _} -> ok
    after ?INTERVAL_MS ->
        case erlang:memory(total) > Limit of
            true -> exceeded(Limit);
            false -> watch(Main, Limit)
        end
    end.

-spec exceeded(pos_integer()) -> no_return().
exceeded(Limit) ->
    io:put_chars(
        standard_error,
        io_lib:format(
            "bouy: the program used more than ~B MiB of memory and was stopped; set BOUY_MAX_MEMORY to change the limit~n",
            [Limit div (1024 * 1024)]
        )
    ),
    erlang:halt(1).
