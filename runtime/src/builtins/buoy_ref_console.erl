%% The console family: Node's util.format and
%% util.inspect (depth 2) over heap values. The layout comes from
%% buoy_console, so lines break where Node breaks them.
-module(buoy_ref_console).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, write/2, format/1, inspect/1]).
-define(DEPTH, 2).
-define(MAX_ITEMS, 100).
-define(CIRCULAR, '$buoy_inspect_circular').

%% The console of the engine has the methods of Node's global console, in its
%% order. log, info, debug, warn, and error print at once, so a program that
%% never uses Node pays nothing for them. The other members are Node's: the
%% first use runs Node's bootstrap, which makes Node's console the global one,
%% and goes on with the member of Node's console.
-define(PRINTS, [<<"log">>, <<"info">>, <<"debug">>, <<"warn">>, <<"error">>]).
-define(NODE_METHODS, [<<"dir">>, <<"time">>, <<"timeEnd">>, <<"timeLog">>, <<"trace">>, <<"assert">>, <<"clear">>,
                       <<"count">>, <<"countReset">>, <<"group">>, <<"groupEnd">>, <<"table">>, <<"dirxml">>,
                       <<"groupCollapsed">>]).
%% The methods that V8's console adds after Console (buoy_binding_inspector),
%% with their lengths.
-define(V8_METHODS, [{<<"profile">>, 0}, {<<"profileEnd">>, 0}, {<<"timeStamp">>, 0}, {<<"context">>, 1},
                     {<<"createTask">>, 0}]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = [{Name, F, 7} || {Name, F} <- ?METHODS(<<"console">>, [{Name, 0} || Name <- ?PRINTS ++ ?NODE_METHODS])],
    Get = buoy_ref_realm:builtin(<<"get console.Console">>, <<"get Console">>, 0, fun(_This, _Args) -> node_member(<<"Console">>) end),
    Set = buoy_ref_realm:builtin(<<"set console.Console">>, <<"set Console">>, 1, fun(This, Args) -> define_member(This, <<"Console">>, buoy_ref_realm:arg(1, Args)) end),
    V8 = [{Name, F, 7} || {Name, F} <- ?METHODS(<<"console">>, ?V8_METHODS)],
    Members = Methods ++ [{<<"Console">>, {'$accessor', Get, Set}, 6} | V8] ++ [{?SYM(toStringTag), <<"console">>, 4}],
    [{'console', buoy_ref_realm:record(object, ?OBJECT_PROTO, Members, none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"console">>, {'$o', 'console'}}].

%% After the bootstrap, a printing method that a program kept from before goes
%% to Node's console too, so it follows console.group and process.stdout.
-spec method(binary(), binary(), term(), list()) -> term().
method(<<"console">>, Name, _This, Args) ->
    case lists:member(Name, ?PRINTS) andalso not buoy_node:ready() of
        true -> write(Name, Args);
        false -> buoy_heap:call(node_member(Name), node_console(), Args)
    end.

node_member(Name) -> buoy_heap:get(node_console(), Name).

%% Node's global console, which require('console') returns even when the
%% program replaced globalThis.console.
node_console() ->
    {ok, Console} = buoy_node:require(<<"console">>),
    Console.

define_member(This, Name, Value) ->
    buoy_heap:define(This, Name, #{value => Value, writable => true, enumerable => true, configurable => true}),
    undefined.

-spec write(binary(), list()) -> undefined.
write(Name, Args) ->
    Device = case Name of
        N when N =:= <<"error">>; N =:= <<"warn">> -> buoy_ref:stderr();
        _ -> persistent_term:get({buoy, stdout}, standard_io)
    end,
    Line = <<(format(Args))/binary, "\n">>,
    try io:put_chars(Device, Line)
    catch
        error:terminated -> ok
    end,
    undefined.

-spec format(list()) -> binary().
format([Template | Args]) when ?IS_STRING(Template), Args =/= [] ->
    {Text, Rest} = substitute(buoy_ref_string:to_utf8(Template), Args, []),
    join([Text | [display(A) || A <- Rest]]);
format(Args) ->
    join([display(A) || A <- Args]).

join(Parts) -> iolist_to_binary(lists:join($\s, Parts)).

display(S) when ?IS_STRING(S) -> buoy_ref_string:to_utf8(S);
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

specifier($s, V) when ?IS_STRING(V) -> {ok, buoy_ref_string:to_utf8(V)};
specifier($s, V) when ?IS_OBJECT(V) -> {ok, inspect(V)};
specifier($s, V) -> {ok, text(V)};
specifier($d, V) -> {ok, text(buoy_ref:to_number(V))};
specifier($i, V) -> {ok, text(buoy_ref_number:method(<<"globalThis">>, <<"parseInt">>, undefined, [V]))};
specifier($f, V) -> {ok, text(buoy_ref_number:method(<<"globalThis">>, <<"parseFloat">>, undefined, [V]))};
specifier($j, V) -> {ok, text(buoy_ref_json:stringify(V, undefined, undefined))};
specifier(C, V) when C =:= $o; C =:= $O -> {ok, inspect(V)};
specifier($%, _) -> percent;
specifier(_, _) -> none.

text(V) when is_number(V) -> buoy_console:number_text(V);
text({'$bigint', I}) -> <<(integer_to_binary(I))/binary, "n">>;
text(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

-spec inspect(term()) -> binary().
inspect(V) ->
    erlang:put(?CIRCULAR, #{}),
    try value(V, 0, 0, [])
    after
        erlang:erase(?CIRCULAR)
    end.

%% Level counts the containers around the value, Indent is the column of
%% its lines, and Stack holds the objects being printed, for [Circular].
value({'$u16', _} = S, _, _, _) ->
    Points = buoy_ref_string:code_points(S),
    case lists:any(fun(C) -> C >= 16#D800 andalso C =< 16#DFFF end, Points) of
        true -> lone_surrogates(Points);
        false -> buoy_console:string(buoy_ref_string:to_utf8(S))
    end;
value(S, _, _, _) when ?IS_STRING(S) -> buoy_console:string(buoy_ref_string:to_utf8(S));
value(N, _, _, _) when is_number(N) -> buoy_console:number_text(N);
value(A, _, _, _) when is_atom(A) -> atom_to_binary(A);
value({'$sym', _, _} = S, _, _, _) -> buoy_ref:describe(S);
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
        Output -> buoy_console:reduce(Output, length(Output), Base, {<<"{">>, <<"}">>}, Indent)
    end;
object(O, Level, Indent, Stack) ->
    case buoy_heap:class_of(O) of
        %% Node prints the target of a proxy.
        proxy -> proxy(O, Level, Indent, Stack);
        array -> array(O, Level, Indent, Stack);
        map -> collection(O, <<"Map">>, map_items(O, Level, Indent, Stack), Level, Indent);
        set -> collection(O, <<"Set">>, [value(K, Level + 1, Indent + 2, Stack) || K <- set_members(O)], Level, Indent);
        promise -> promise(O, Level, Indent, Stack);
        error -> error_text(O);
        generator -> <<"Object [Generator] {}">>;
        weakmap -> <<"WeakMap { <items unknown> }">>;
        weakset -> <<"WeakSet { <items unknown> }">>;
        list_iterator -> <<"Object [", (element(1, buoy_heap:slots(O)))/binary, "] {}">>;
        date -> buoy_ref_date:inspect(O);
        typed_array -> typed_array(O, Level, Indent, Stack);
        data_view -> data_view(O, Level, Indent, Stack);
        map_iterator -> collection_iterator(O, Level, Indent, Stack);
        set_iterator -> collection_iterator(O, Level, Indent, Stack);
        array_iterator -> <<"Object [Array Iterator] {}">>;
        string_iterator -> <<"Object [String Iterator] {}">>;
        array_buffer -> array_buffer(O, Indent);
        number -> wrapper(<<"Number">>, O, Level, Indent, Stack);
        string -> wrapper(<<"String">>, O, Level, Indent, Stack);
        boolean -> wrapper(<<"Boolean">>, O, Level, Indent, Stack);
        bigint -> wrapper(<<"BigInt">>, O, Level, Indent, Stack);
        symbol -> wrapper(<<"Symbol">>, O, Level, Indent, Stack);
        regexp -> buoy_ref_regexp:display(O);
        _ -> plain(O, Level, Indent, Stack)
    end.

proxy(O, Level, Indent, Stack) ->
    case buoy_heap:slots(O) of
        {revoked, _} -> <<"<Revoked Proxy>">>;
        {Target, _} -> object(Target, Level, Indent, Stack)
    end.

%% A string with a lone surrogate, which Node prints as an escape.
lone_surrogates(Points) ->
    Has = fun(C) -> lists:member(C, Points) end,
    Quote = case {Has($'), Has($")} of
        {false, _} -> $';
        {true, false} -> $";
        {true, true} -> $'
    end,
    iolist_to_binary([Quote, [point(C, Quote) || C <- Points], Quote]).

point(C, C) -> [$\\, C];
point($\\, _) -> <<"\\\\">>;
point($\n, _) -> <<"\\n">>;
point($\t, _) -> <<"\\t">>;
point(C, _) when C >= 16#D800, C =< 16#DFFF -> io_lib:format("\\u~4.16.0b", [C]);
point(C, _) when C < 16#20 -> io_lib:format("\\x~2.16.0B", [C]);
point(C, _) -> <<C/utf8>>.

%% A typed array, as Node prints it: Uint8Array(2) [ 1, 2 ].
typed_array(O, Level, Indent, Stack) ->
    Name = buoy_ref:to_string(buoy_ref:get(O, ?SYM(toStringTag))),
    Length = buoy_ref:get(O, <<"length">>),
    Base = <<Name/binary, "(", (integer_to_binary(Length))/binary, ")">>,
    case Length of
        0 -> <<Base/binary, " []">>;
        _ when Level > ?DEPTH -> <<"[", Name/binary, "]">>;
        _ ->
            Values = [buoy_heap:get(O, I) || I <- lists:seq(0, min(Length, ?MAX_ITEMS) - 1)],
            Output = [value(V, Level + 1, Indent + 2, Stack) || V <- Values] ++ buoy_console:more_items(Length),
            buoy_console:reduce(buoy_console:group(Output, Values, Indent), length(Output), Base, {<<"[">>, <<"]">>}, Indent)
    end.

%% A DataView with its byteLength, byteOffset, and buffer.
data_view(O, Level, Indent, Stack) ->
    {Buffer, Offset, _} = buoy_heap:slots(O),
    Length = try buoy_ref:get(O, <<"byteLength">>) catch error:{'$throw', _} -> 0 end,
    Entries = [<<"[byteLength]: ", (value(Length, Level + 1, Indent + 2, Stack))/binary>>,
               <<"[byteOffset]: ", (value(Offset, Level + 1, Indent + 2, Stack))/binary>>,
               <<"[buffer]: ", (array_buffer(Buffer, Indent + 2))/binary>>],
    buoy_console:reduce(Entries, 3, <<"DataView">>, {<<"{">>, <<"}">>}, Indent).

%% A Map or Set iterator with the entries it has yet to give.
collection_iterator(O, Level, Indent, Stack) ->
    {Label, Items} = buoy_ref_collection:remaining(O),
    Shown = [case Item of
                 [K, V] -> <<"[ ", (value(K, Level + 2, Indent + 4, Stack))/binary, ", ", (value(V, Level + 2, Indent + 4, Stack))/binary, " ]">>;
                 V -> value(V, Level + 1, Indent + 2, Stack)
             end || Item <- Items],
    case Shown of
        [] -> <<"[", Label/binary, "] {  }">>;
        _ -> buoy_console:reduce(Shown, length(Shown), <<"[", Label/binary, "]">>, {<<"{">>, <<"}">>}, Indent)
    end.

%% An ArrayBuffer, with its bytes in hex, as Node prints it.
array_buffer(O, Indent) ->
    case buoy_ref_buffer:is_detached(O) of
        true -> <<"ArrayBuffer { (detached), [byteLength]: 0 }">>;
        false ->
            Length = buoy_ref_buffer:byte_length(O),
            Bytes = buoy_ref_buffer:read(O, 0, min(Length, 50)),
            Hex = lists:join(" ", [io_lib:format("~2.16.0b", [B]) || <<B>> <= Bytes]),
            More = case Length > 50 of
                true -> io_lib:format(" ... ~w more byte~s", [Length - 50, case Length - 50 of 1 -> ""; _ -> "s" end]);
                false -> ""
            end,
            Entries = [iolist_to_binary(["[Uint8Contents]: <", Hex, More, ">"]), <<"[byteLength]: ", (integer_to_binary(Length))/binary>>],
            buoy_console:reduce(Entries, 2, <<"ArrayBuffer">>, {<<"{">>, <<"}">>}, Indent)
    end.

%% A primitive wrapper object, as Node prints it: [Number: 5].
wrapper(Name, O, Level, Indent, Stack) ->
    <<"[", Name/binary, ": ", (value(buoy_heap:slots(O), Level, Indent, Stack))/binary, "]">>.

plain(O, Level, Indent, Stack) ->
    Prefix = prefix(O),
    case own_entries(O, Level, Indent, Stack) of
        [] -> <<Prefix/binary, "{}">>;
        _ when Level > ?DEPTH -> bracket(Prefix);
        Output -> buoy_console:reduce(Output, length(Output), trim(Prefix), {<<"{">>, <<"}">>}, Indent)
    end.

bracket(<<>>) -> <<"[Object]">>;
bracket(Prefix) -> <<"[", (trim(Prefix))/binary, "]">>.

trim(<<>>) -> <<>>;
trim(Prefix) -> binary:part(Prefix, 0, byte_size(Prefix) - 1).

%% The constructor name that Node prints before the braces: none for a plain
%% object, `[Object: null prototype]` without a prototype.
prefix(O) ->
    case buoy_heap:prototype_of(O) of
        null when element(1, O) =:= '$o' ->
            case buoy_heap:class_of(O) of
                namespace -> <<"[Module: null prototype] ">>;
                _ -> <<"[Object: null prototype] ">>
            end;
        null -> <<"[Object: null prototype] ">>;
        _ -> tagged(constructor_name(O), tag(O))
    end.

%% Node adds Symbol.toStringTag in brackets when it differs from the
%% constructor name, as in `Object [Reflect] {}`.
tagged(Name, Tag) when Tag =/= <<>>, Tag =/= Name ->
    <<(case Name of undefined -> <<"Object">>; _ -> Name end)/binary, " [", Tag/binary, "] ">>;
tagged(<<"Object">>, _Tag) -> <<>>;
tagged(undefined, _Tag) -> <<>>;
tagged(Name, _Tag) -> <<Name/binary, " ">>.

%% An own enumerable tag prints as a property already, so it is not repeated.
tag(O) ->
    Own = case buoy_heap:get_own(O, ?SYM(toStringTag)) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end,
    case buoy_heap:get(O, ?SYM(toStringTag)) of
        T when ?IS_STRING(T), not Own -> buoy_ref_string:to_utf8(T);
        _ -> <<>>
    end.

constructor_name(null) ->
    undefined;
constructor_name(O) ->
    case buoy_heap:get_own(O, <<"constructor">>) of
        {data, {'$f', _, _} = C, _} ->
            case buoy_ref:get(C, <<"name">>) of
                Name when ?IS_STRING(Name), Name =/= <<>> -> buoy_ref_string:to_utf8(Name);
                _ -> constructor_name(buoy_heap:prototype_of(O))
            end;
        _ ->
            constructor_name(buoy_heap:prototype_of(O))
    end.

own_entries(O, Level, Indent, Stack) ->
    [entry(O, K, Level, Indent, Stack) || K <- buoy_heap:own_keys(O), enumerable(O, K)].

enumerable(O, K) ->
    case buoy_heap:get_own(O, K) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end.

entry(O, K, Level, Indent, Stack) ->
    Shown = case buoy_heap:get_own(O, K) of
        {data, V, _} -> value(V, Level + 1, Indent + 2, Stack);
        {accessor, G, undefined, _} when G =/= undefined -> <<"[Getter]">>;
        {accessor, undefined, _, _} -> <<"[Setter]">>;
        {accessor, _, _, _} -> <<"[Getter/Setter]">>
    end,
    <<(key(K))/binary, ": ", Shown/binary>>.

key(K) when is_integer(K) -> <<"'", (integer_to_binary(K))/binary, "'">>;
key(K) when ?IS_STRING(K) -> buoy_console:key(buoy_ref_string:to_utf8(K));
key({'$sym', _, _} = S) -> buoy_ref:describe(S).

array(A, Level, Indent, Stack) ->
    Length = buoy_heap:array_length(A),
    case Length of
        0 -> <<"[]">>;
        _ when Level > ?DEPTH -> <<"[Array]">>;
        _ ->
            Slots = [case buoy_heap:has_own(A, I) of
                         true -> {item, buoy_heap:get(A, I)};
                         false -> hole
                     end || I <- lists:seq(0, min(Length, ?MAX_ITEMS) - 1)],
            {Output, Values} = holes(Slots, Level, Indent, Stack),
            All = Output ++ buoy_console:more_items(Length),
            buoy_console:reduce(buoy_console:group(All, Values, Indent), length(All), <<>>, {<<"[">>, <<"]">>}, Indent)
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
    {Index, _} = buoy_heap:slots(M),
    Entries = [{K, V} || {_, K, V} <- lists:sort([{Seq, K, V} || K := {Seq, V} <- Index])],
    [<<(value(K, Level + 1, Indent + 2, Stack))/binary, " => ", (value(V, Level + 1, Indent + 2, Stack))/binary>> || {K, V} <- Entries].

set_members(S) ->
    {Index, _} = buoy_heap:slots(S),
    [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])].

collection(_O, Name, [], _Level, _Indent) ->
    <<Name/binary, "(0) {}">>;
collection(_O, Name, _Items, Level, _Indent) when Level > ?DEPTH ->
    <<"[", Name/binary, "]">>;
collection(_O, Name, Items, _Level, Indent) ->
    Open = <<Name/binary, "(", (integer_to_binary(length(Items)))/binary, ") {">>,
    buoy_console:reduce(Items, length(Items), <<>>, {Open, <<"}">>}, Indent).

promise(P, Level, Indent, Stack) ->
    Inner = case buoy_heap:slots(P) of
        {pending, _, _, _} -> <<"<pending>">>;
        {fulfilled, V, _} -> value(V, Level + 1, Indent + 2, Stack);
        {rejected, R, _} -> <<"<rejected> ", (value(R, Level + 1, Indent + 2, Stack))/binary>>
    end,
    buoy_console:reduce([Inner], 1, <<>>, {<<"Promise {">>, <<"}">>}, Indent).

%% Node prints the stack of an error. Buoy keeps no JavaScript stack, so it
%% prints the first line.
error_text(E) ->
    case buoy_ref:get(E, <<"stack">>) of
        Stack when ?IS_STRING(Stack) -> hd(binary:split(buoy_ref_string:to_utf8(Stack), <<"\n">>));
        _ -> buoy_ref_string:to_utf8(buoy_ref_error:error_to_string(E))
    end.

function_label(F) ->
    Name = case buoy_ref:get(F, <<"name">>) of
        N when ?IS_STRING(N) -> buoy_ref_string:to_utf8(N);
        _ -> <<>>
    end,
    case buoy_heap:slots(F) of
        #{kind := class, parent := Parent} ->
            Extends = case Parent of
                {'$f', _, _} -> <<" extends ", (text(buoy_ref:get(Parent, <<"name">>)))/binary>>;
                _ -> <<>>
            end,
            <<"[class ", Name/binary, Extends/binary, "]">>;
        Slots ->
            Kind = case Slots of
                #{kind := generator} -> <<"GeneratorFunction">>;
                #{kind := async} -> <<"AsyncFunction">>;
                #{kind := async_generator} -> <<"AsyncGeneratorFunction">>;
                _ -> <<"Function">>
            end,
            case Name of
                <<>> -> <<"[", Kind/binary, " (anonymous)]">>;
                _ -> <<"[", Kind/binary, ": ", Name/binary, "]">>
            end
    end.
