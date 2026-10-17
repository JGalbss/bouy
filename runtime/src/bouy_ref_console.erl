%% The console family: Node's util.format and
%% util.inspect (depth 2) over heap values. The layout comes from
%% bouy_console, so lines break where Node breaks them.
-module(bouy_ref_console).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, write/2, format/1, inspect/1]).
-define(DEPTH, 2).
-define(MAX_ITEMS, 100).
-define(CIRCULAR, '$bouy_inspect_circular').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'console', bouy_ref_realm:record(object, ?OBJECT_PROTO, ?METHODS(<<"console">>, [<<"log">>, <<"error">>, <<"warn">>, <<"info">>, <<"debug">>]), none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"console">>, {'$o', 'console'}}].

-spec method(binary(), binary(), term(), list()) -> undefined.
method(<<"console">>, Name, _This, Args) -> write(Name, Args).

-spec write(binary(), list()) -> undefined.
write(Name, Args) ->
    Device = case Name of
        N when N =:= <<"error">>; N =:= <<"warn">> -> bouy_ref:stderr();
        _ -> persistent_term:get({bouy, stdout}, standard_io)
    end,
    Line = <<(format(Args))/binary, "\n">>,
    try io:put_chars(Device, Line)
    catch
        error:terminated -> ok
    end,
    undefined.

-spec format(list()) -> binary().
format([Template | Args]) when ?IS_STRING(Template), Args =/= [] ->
    {Text, Rest} = substitute(bouy_ref_string:to_utf8(Template), Args, []),
    join([Text | [display(A) || A <- Rest]]);
format(Args) ->
    join([display(A) || A <- Args]).

join(Parts) -> iolist_to_binary(lists:join($\s, Parts)).

display(S) when ?IS_STRING(S) -> bouy_ref_string:to_utf8(S);
display(V) -> inspect(V).

substitute(<<"%", C, Rest/binary>>, [Arg | Args] = All, Acc) ->
    case specifier(C, Arg) of
        {ok, Text} -> substitute(Rest, Args, [Text | Acc]);
        percent -> substitute(Rest, All, [$% | Acc]);
        none -> substitute(<<C, Rest/binary>>, All, [$% | Acc])
    end;
substitute(<<C, Rest/binary>>, Args, Acc) ->
    substitute(Rest, Args, [C | Acc]);
substitute(<<>>, Args, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Args}.

specifier($s, V) when ?IS_STRING(V) -> {ok, bouy_ref_string:to_utf8(V)};
specifier($s, V) when ?IS_OBJECT(V) -> {ok, inspect(V)};
specifier($s, V) -> {ok, text(V)};
specifier($d, V) -> {ok, text(bouy_ref:to_number(V))};
specifier($i, V) -> {ok, text(bouy_ref_number:method(<<"globalThis">>, <<"parseInt">>, undefined, [V]))};
specifier($f, V) -> {ok, text(bouy_ref_number:method(<<"globalThis">>, <<"parseFloat">>, undefined, [V]))};
specifier($j, V) -> {ok, text(bouy_ref_json:stringify(V, undefined, undefined))};
specifier(C, V) when C =:= $o; C =:= $O -> {ok, inspect(V)};
specifier($%, _) -> percent;
specifier(_, _) -> none.

text(V) when is_number(V) -> bouy_console:number_text(V);
text({'$bigint', I}) -> <<(integer_to_binary(I))/binary, "n">>;
text(V) -> bouy_ref_string:to_utf8(bouy_ref:to_string(V)).

-spec inspect(term()) -> binary().
inspect(V) ->
    erlang:put(?CIRCULAR, #{}),
    try value(V, 0, 0, [])
    after
        erlang:erase(?CIRCULAR)
    end.

%% Level counts the containers around the value, Indent is the column of
%% its lines, and Stack holds the objects being printed, for [Circular].
value(S, _, _, _) when ?IS_STRING(S) -> bouy_console:string(bouy_ref_string:to_utf8(S));
value(N, _, _, _) when is_number(N) -> bouy_console:number_text(N);
value(A, _, _, _) when is_atom(A) -> atom_to_binary(A);
value({'$sym', _, _} = S, _, _, _) -> bouy_ref:describe(S);
value({'$bigint', I}, _, _, _) -> <<(integer_to_binary(I))/binary, "n">>;
value({'$actor', _}, _, _, _) -> <<"[ActorRef]">>;
value(V, Level, Indent, Stack) when ?IS_OBJECT(V) ->
    case lists:member(V, Stack) of
        true -> <<"[Circular *", (integer_to_binary(circular(V)))/binary, "]">>;
        false -> with_ref(V, object(V, Level, Indent, [V | Stack]))
    end;
value(Other, _, _, _) -> unicode:characters_to_binary(io_lib:format("~0tp", [Other])).

circular(V) ->
    Seen = erlang:get(?CIRCULAR),
    case Seen of
        #{V := N} -> N;
        _ ->
            N = map_size(Seen) + 1,
            erlang:put(?CIRCULAR, Seen#{V => N}),
            N
    end.

with_ref(V, Text) ->
    case erlang:get(?CIRCULAR) of
        #{V := N} -> <<"<ref *", (integer_to_binary(N))/binary, "> ", Text/binary>>;
        _ -> Text
    end.

object({'$f', _, _} = F, Level, Indent, Stack) ->
    Base = function_label(F),
    case own_entries(F, Level, Indent, Stack) of
        [] -> Base;
        _ when Level > ?DEPTH -> Base;
        Output -> bouy_console:reduce(Output, length(Output), Base, {<<"{">>, <<"}">>}, Indent)
    end;
object(O, Level, Indent, Stack) ->
    case bouy_heap:class_of(O) of
        array -> array(O, Level, Indent, Stack);
        map -> collection(O, <<"Map">>, map_items(O, Level, Indent, Stack), Level, Indent);
        set -> collection(O, <<"Set">>, [value(K, Level + 1, Indent + 2, Stack) || K <- set_members(O)], Level, Indent);
        promise -> promise(O, Level, Indent, Stack);
        error -> error_text(O);
        generator -> <<"Object [Generator] {}">>;
        list_iterator -> <<"Object [", (element(1, bouy_heap:slots(O)))/binary, "] {}">>;
        date -> bouy_date:call(<<"toISOString">>, {'$date', bouy_heap:slots(O)}, []);
        number -> wrapper(<<"Number">>, O, Level, Indent, Stack);
        string -> wrapper(<<"String">>, O, Level, Indent, Stack);
        boolean -> wrapper(<<"Boolean">>, O, Level, Indent, Stack);
        bigint -> wrapper(<<"BigInt">>, O, Level, Indent, Stack);
        symbol -> wrapper(<<"Symbol">>, O, Level, Indent, Stack);
        _ -> plain(O, Level, Indent, Stack)
    end.

%% A primitive wrapper object, as Node prints it: [Number: 5].
wrapper(Name, O, Level, Indent, Stack) ->
    <<"[", Name/binary, ": ", (value(bouy_heap:slots(O), Level, Indent, Stack))/binary, "]">>.

plain(O, Level, Indent, Stack) ->
    Prefix = prefix(O),
    case own_entries(O, Level, Indent, Stack) of
        [] -> <<Prefix/binary, "{}">>;
        _ when Level > ?DEPTH -> bracket(Prefix);
        Output -> bouy_console:reduce(Output, length(Output), trim(Prefix), {<<"{">>, <<"}">>}, Indent)
    end.

bracket(<<>>) -> <<"[Object]">>;
bracket(Prefix) -> <<"[", (trim(Prefix))/binary, "]">>.

trim(<<>>) -> <<>>;
trim(Prefix) -> binary:part(Prefix, 0, byte_size(Prefix) - 1).

%% The constructor name that Node prints before the braces: none for a plain
%% object, `[Object: null prototype]` without a prototype.
prefix(O) ->
    case bouy_heap:prototype_of(O) of
        null -> <<"[Object: null prototype] ">>;
        _ ->
            case constructor_name(O) of
                <<"Object">> -> <<>>;
                undefined -> <<>>;
                Name -> <<Name/binary, " ">>
            end
    end.

constructor_name(null) ->
    undefined;
constructor_name(O) ->
    case bouy_heap:get_own(O, <<"constructor">>) of
        {data, {'$f', _, _} = C, _} ->
            case bouy_ref:get(C, <<"name">>) of
                Name when ?IS_STRING(Name), Name =/= <<>> -> bouy_ref_string:to_utf8(Name);
                _ -> constructor_name(bouy_heap:prototype_of(O))
            end;
        _ ->
            constructor_name(bouy_heap:prototype_of(O))
    end.

own_entries(O, Level, Indent, Stack) ->
    [entry(O, K, Level, Indent, Stack) || K <- bouy_heap:own_keys(O), enumerable(O, K)].

enumerable(O, K) ->
    case bouy_heap:get_own(O, K) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end.

entry(O, K, Level, Indent, Stack) ->
    Shown = case bouy_heap:get_own(O, K) of
        {data, V, _} -> value(V, Level + 1, Indent + 2, Stack);
        {accessor, G, undefined, _} when G =/= undefined -> <<"[Getter]">>;
        {accessor, undefined, _, _} -> <<"[Setter]">>;
        {accessor, _, _, _} -> <<"[Getter/Setter]">>
    end,
    <<(key(K))/binary, ": ", Shown/binary>>.

key(K) when is_integer(K) -> <<"'", (integer_to_binary(K))/binary, "'">>;
key(K) when ?IS_STRING(K) -> bouy_console:key(bouy_ref_string:to_utf8(K));
key({'$sym', _, _} = S) -> bouy_ref:describe(S).

array(A, Level, Indent, Stack) ->
    Length = bouy_heap:array_length(A),
    case Length of
        0 -> <<"[]">>;
        _ when Level > ?DEPTH -> <<"[Array]">>;
        _ ->
            Slots = [case bouy_heap:has_own(A, I) of
                         true -> {item, bouy_heap:get(A, I)};
                         false -> hole
                     end || I <- lists:seq(0, min(Length, ?MAX_ITEMS) - 1)],
            {Output, Values} = holes(Slots, Level, Indent, Stack),
            All = Output ++ bouy_console:more_items(Length),
            bouy_console:reduce(bouy_console:group(All, Values, Indent), length(All), <<>>, {<<"[">>, <<"]">>}, Indent)
    end.

%% Runs of holes print as one `<N empty items>` entry.
holes([], _, _, _) -> {[], []};
holes([hole | _] = Slots, Level, Indent, Stack) ->
    {Holes, Rest} = lists:splitwith(fun(S) -> S =:= hole end, Slots),
    {Output, Values} = holes(Rest, Level, Indent, Stack),
    Text = case length(Holes) of
        1 -> <<"<1 empty item>">>;
        N -> <<"<", (integer_to_binary(N))/binary, " empty items>">>
    end,
    {[Text | Output], [hole | Values]};
holes([{item, V} | Rest], Level, Indent, Stack) ->
    {Output, Values} = holes(Rest, Level, Indent, Stack),
    {[value(V, Level + 1, Indent + 2, Stack) | Output], [V | Values]}.

map_items(M, Level, Indent, Stack) ->
    {Index, _} = bouy_heap:slots(M),
    Entries = [{K, V} || {_, K, V} <- lists:sort([{Seq, K, V} || K := {Seq, V} <- Index])],
    [<<(value(K, Level + 1, Indent + 2, Stack))/binary, " => ", (value(V, Level + 1, Indent + 2, Stack))/binary>> || {K, V} <- Entries].

set_members(S) ->
    {Index, _} = bouy_heap:slots(S),
    [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])].

collection(_O, Name, [], _Level, _Indent) ->
    <<Name/binary, "(0) {}">>;
collection(_O, Name, _Items, Level, _Indent) when Level > ?DEPTH ->
    <<"[", Name/binary, "]">>;
collection(_O, Name, Items, _Level, Indent) ->
    Open = <<Name/binary, "(", (integer_to_binary(length(Items)))/binary, ") {">>,
    bouy_console:reduce(Items, length(Items), <<>>, {Open, <<"}">>}, Indent).

promise(P, Level, Indent, Stack) ->
    Inner = case bouy_heap:slots(P) of
        {pending, _, _, _} -> <<"<pending>">>;
        {fulfilled, V, _} -> value(V, Level + 1, Indent + 2, Stack);
        {rejected, R, _} -> <<"<rejected> ", (value(R, Level + 1, Indent + 2, Stack))/binary>>
    end,
    bouy_console:reduce([Inner], 1, <<>>, {<<"Promise {">>, <<"}">>}, Indent).

%% Node prints the stack of an error. Bouy keeps no JavaScript stack, so it
%% prints the first line.
error_text(E) ->
    case bouy_ref:get(E, <<"stack">>) of
        Stack when ?IS_STRING(Stack) -> hd(binary:split(bouy_ref_string:to_utf8(Stack), <<"\n">>));
        _ -> bouy_ref_string:to_utf8(bouy_ref_error:error_to_string(E))
    end.

function_label(F) ->
    Name = case bouy_ref:get(F, <<"name">>) of
        N when ?IS_STRING(N) -> bouy_ref_string:to_utf8(N);
        _ -> <<>>
    end,
    case bouy_heap:slots(F) of
        #{kind := class, parent := Parent} ->
            Extends = case Parent of
                {'$f', _, _} -> <<" extends ", (text(bouy_ref:get(Parent, <<"name">>)))/binary>>;
                _ -> <<>>
            end,
            <<"[class ", Name/binary, Extends/binary, "]">>;
        _ when Name =:= <<>> -> <<"[Function (anonymous)]">>;
        _ -> <<"[Function: ", Name/binary, "]">>
    end.
