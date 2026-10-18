%% The random bytes and primes of internalBinding('crypto')
%% (src/crypto/crypto_random.cc and the secure buffers of crypto_util.cc):
%% randomFill, randomUUID, generatePrime, and checkPrime.
-module(buoy_crypto_random).

-export([members/0, generate_prime/4, is_prime/2]).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"RandomBytesJob">>, buoy_crypto_job:class(<<"RandomBytesJob">>, fun random_bytes_job/1)},
     {<<"RandomPrimeJob">>, buoy_crypto_job:class(<<"RandomPrimeJob">>, fun random_prime_job/1)},
     {<<"CheckPrimeJob">>, buoy_crypto_job:class(<<"CheckPrimeJob">>, fun check_prime_job/1)},
     {<<"secureBuffer">>, buoy_node:fn(<<"secureBuffer">>, 1, fun(_, Args) ->
         buoy_node:typed_array(<<"Uint8Array">>, buoy_crypto:to_uint32(buoy_node:arg(1, Args)))
     end)},
     %% undefined while no secure heap is initialized (CRYPTO_secure_malloc_initialized):
     %% Buoy keeps none, as Node without --secure-heap.
     {<<"secureHeapUsed">>, buoy_node:fn(<<"secureHeapUsed">>, 0, fun(_, _) -> undefined end)}].

%% new RandomBytesJob(mode, buffer, offset, size): the bytes go into the
%% buffer when the job is done.
random_bytes_job([Buffer, Offset, Size | _]) ->
    {fun() -> {ok, crypto:strong_rand_bytes(Size)} end,
     fun(Bytes) -> buoy_node_encoding:view_write(Buffer, Offset, Bytes), undefined end}.

%% new RandomPrimeJob(mode, size, safe, add, rem)
random_prime_job([Bits, Safe | Rest]) ->
    [AddValue, RemValue | _] = Rest ++ [undefined, undefined],
    Add = optional_integer(AddValue),
    Rem = optional_integer(RemValue),
    case Add of
        undefined -> ok;
        _ when Add > 0 ->
            bit_length(Add) > Bits andalso
                buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"invalid options.add">>),
            is_integer(Rem) andalso Add =< Rem andalso
                buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"invalid options.rem">>);
        _ -> ok
    end,
    {fun() -> {ok, generate_prime(Bits, Safe =:= true, Add, Rem)} end,
     fun(Prime) -> buoy_crypto:array_buffer(binary:encode_unsigned(Prime)) end}.

optional_integer(undefined) -> undefined;
optional_integer(V) -> binary:decode_unsigned(buoy_crypto:bytes(V)).

%% new CheckPrimeJob(mode, candidate, checks)
check_prime_job([Candidate, Checks | _]) ->
    Bytes = buoy_crypto:bytes(Candidate),
    %% BN_bin2bn takes at most INT_MAX / 4 bits.
    byte_size(Bytes) > 16#7FFFFFFF div 32 andalso buoy_crypto:fail({openssl, bignum_too_long}),
    N = binary:decode_unsigned(Bytes),
    {fun() -> {ok, is_prime(N, Checks)} end, fun(Prime) -> Prime end}.

%%% Primes

%% A random prime of Bits bits, as BN_generate_prime_ex2 makes one: a safe
%% prime has (p - 1) / 2 prime too, and with Add, p mod Add is Rem (1, or 3
%% for a safe prime, when Rem is undefined).
-spec generate_prime(pos_integer(), boolean(), undefined | non_neg_integer(), undefined | non_neg_integer()) -> non_neg_integer().
generate_prime(Bits, Safe, Add, Rem) when Bits < 32 ->
    Candidate = candidate(Bits, Safe, Add, Rem),
    case is_prime(Candidate, 0) andalso (not Safe orelse is_prime(Candidate bsr 1, 0)) of
        true -> Candidate;
        false -> generate_prime(Bits, Safe, Add, Rem)
    end;
generate_prime(Bits, Safe, Add, Rem) ->
    %% As OpenSSL's probable_prime, step from a random start and sieve each
    %% candidate by its residues modulo the small primes, kept as small
    %% integers, before any modular exponentiation.
    Start = candidate(Bits, Safe, Add, Rem),
    Step = case {Add, Safe} of
        {undefined, true} -> 4;
        {undefined, false} -> 2;
        _ -> Add
    end,
    Residues = [{P, Start rem P} || P <- sieve_primes()],
    search(Bits, Safe, Add, Rem, Start, Step, Residues, 0).

search(Bits, Safe, Add, Rem, Start, Step, Residues, K) ->
    Offset = K * Step,
    Candidate = Start + Offset,
    case bit_length(Candidate) > Bits of
        true -> generate_prime(Bits, Safe, Add, Rem);
        false ->
            case sieved(Residues, Offset, Safe) andalso probable(Candidate, Safe) of
                true -> Candidate;
                false -> search(Bits, Safe, Add, Rem, Start, Step, Residues, K + 1)
            end
    end.

%% Whether no small odd prime divides the candidate, or (p - 1) / 2 for a
%% safe prime, which a residue of 1 shows.
sieved([], _, _) -> true;
sieved([{P, R} | Rest], Offset, Safe) ->
    case (R + Offset) rem P of
        0 -> false;
        1 when Safe -> false;
        _ -> sieved(Rest, Offset, Safe)
    end.

%% A Fermat test to the base 2 rejects nearly every composite with one
%% exponentiation, and the full Miller-Rabin rounds confirm the rest.
probable(N, Safe) ->
    Q = N bsr 1,
    pow(2, N - 1, N) =:= 1 andalso (not Safe orelse pow(2, Q - 1, Q) =:= 1) andalso
        is_prime(N, 0) andalso (not Safe orelse is_prime(Q, 0)).

candidate(Bits, Safe, undefined, _) when Bits >= 2 ->
    %% The top two bits and the bottom bit set, and bit 1 too for a safe prime.
    R = random_bits(Bits) bor (3 bsl (Bits - 2)) bor 1,
    case Safe of
        true -> R bor 2;
        false -> R
    end;
candidate(Bits, Safe, Add, Rem) when is_integer(Add), Add > 0 ->
    R = random_bits(Bits) bor (1 bsl (Bits - 1)),
    Offset = case Rem of
        undefined when Safe -> 3;
        undefined -> 1;
        _ -> Rem
    end,
    C = R - (R rem Add) + Offset,
    Small = case Safe of
        true -> 5;
        false -> 3
    end,
    case bit_length(C) < Bits orelse C < Small of
        true -> C + Add;
        false -> C
    end;
candidate(_, _, _, _) ->
    erlang:error({error, {"bn_prime.c", 0}, "bits too small"}).

random_bits(Bits) ->
    Bytes = (Bits + 7) div 8,
    binary:decode_unsigned(crypto:strong_rand_bytes(Bytes)) band ((1 bsl Bits) - 1).

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.

%% Miller-Rabin with Checks rounds, or the rounds that OpenSSL 3 takes for
%% the size (64, or 128 above 2048 bits) when Checks is 0, after trial
%% division by the small primes.
-spec is_prime(non_neg_integer(), non_neg_integer()) -> boolean().
is_prime(N, _) when N < 2 -> false;
is_prime(N, Checks) ->
    case small_factor(N) of
        prime -> true;
        composite -> false;
        unknown ->
            Rounds = case Checks of
                0 when N >= 1 bsl 2048 -> 128;
                0 -> 64;
                _ -> Checks
            end,
            {D, S} = odd_part(N - 1, 0),
            lists:all(fun(_) -> witness(N, D, S, 2 + rand_below(N - 3)) end, lists:seq(1, Rounds))
    end.

small_factor(N) ->
    Primes = small_primes(),
    case N =< 2048 of
        true ->
            case lists:member(N, Primes) of
                true -> prime;
                false -> composite
            end;
        false ->
            case lists:any(fun(P) -> N rem P =:= 0 end, Primes) of
                true -> composite;
                false -> unknown
            end
    end.

%% The odd primes below 2048, made once per node: trial division by them
%% rejects most candidates before a Miller-Rabin round.
small_primes() ->
    case persistent_term:get({?MODULE, small_primes}, undefined) of
        undefined ->
            Primes = sieve(lists:seq(2, 2048)),
            persistent_term:put({?MODULE, small_primes}, Primes),
            Primes;
        Primes -> Primes
    end.

%% The 2047 odd primes below 17864 that OpenSSL's primes table holds, made
%% once per node, for the sieve of a prime search.
sieve_primes() ->
    case persistent_term:get({?MODULE, sieve_primes}, undefined) of
        undefined ->
            Divisors = [P || P <- tl(small_primes()), P * P =< 17863],
            Primes = [N || N <- lists:seq(3, 17863, 2),
                           not lists:any(fun(P) -> P * P =< N andalso N rem P =:= 0 end, Divisors)],
            persistent_term:put({?MODULE, sieve_primes}, Primes),
            Primes;
        Primes -> Primes
    end.

sieve([]) -> [];
sieve([P | Rest]) -> [P | sieve([X || X <- Rest, X rem P =/= 0])].

odd_part(D, S) when D band 1 =:= 0 -> odd_part(D bsr 1, S + 1);
odd_part(D, S) -> {D, S}.

%% A random integer in [0, N).
rand_below(N) when N =< 1 -> 0;
rand_below(N) -> binary:decode_unsigned(crypto:strong_rand_bytes((bit_length(N) + 7) div 8 + 8)) rem N.

%% Whether N is a probable prime to the base A.
witness(N, D, S, A) ->
    X = pow(A, D, N),
    X =:= 1 orelse X =:= N - 1 orelse squares(X, S - 1, N).

squares(_, 0, _) -> false;
squares(X, R, N) ->
    case pow(X, 2, N) of
        Y when Y =:= N - 1 -> true;
        1 -> false;
        Y -> squares(Y, R - 1, N)
    end.

pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).
