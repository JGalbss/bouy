%% `console`: Node's `util.format` and a subset of `util.inspect` with its
%% defaults (depth 2, breakLength 80, compact 3, maxStringLength 10000).
%% Errors print as `Name: message` without stack frames.
-module(bouy_console).

-compile({no_auto_import, [error/1]}).

-export(['$member'/1, log/1, error/1, warn/1, info/1, debug/1]).
-export([format/1, inspect/1, inspect/2, function_name/1]).

-define(FUNCTIONS, [<<"log">>, <<"error">>, <<"warn">>, <<"info">>, <<"debug">>]).
-define(BREAK_LENGTH, 80).
-define(MAX_ITEMS, 100).
-define(MAX_STRING, 10000).

%% Depth is the nesting that prints in full, and Hidden adds the hidden
%% properties that `%o` shows, such as the `[length]` of an array.
-record(ctx, {depth :: non_neg_integer(), hidden = false :: boolean()}).

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

-spec log(list()) -> undefined.
log(Args) -> write(standard_io, Args).

-spec info(list()) -> undefined.
info(Args) -> write(standard_io, Args).

-spec debug(list()) -> undefined.
debug(Args) -> write(standard_io, Args).

-spec error(list()) -> undefined.
error(Args) -> write(standard_error, Args).

-spec warn(list()) -> undefined.
warn(Args) -> write(standard_error, Args).

%% The bytes are UTF-8 whatever the device encoding is: a unicode device
%% takes them as characters, a latin1 device as raw bytes. A write to a
%% closed stdout, as in `bouy run app.ts | head -1`, is dropped, as Node does.
write(Device, Args) ->
    Line = <<(format(Args))/binary, "\n">>,
    Target = device(Device),
    try
        case encoding(Target) of
            unicode -> io:put_chars(Target, Line);
            latin1 -> file:write(Target, Line)
        end
    catch
        error:terminated -> ok
    end,
    undefined.

%% Standard output is the group leader of the top-level code, for actors too.
%% The group leader of an application process forwards each request to it,
%% and it never answers once the writer of a closed pipe has crashed.
device(standard_io) -> persistent_term:get({bouy, stdout}, standard_io);
device(Device) -> Device.

encoding(Device) ->
    case erlang:get({?MODULE, Device}) of
        undefined ->
            Encoding = device_encoding(Device),
            erlang:put({?MODULE, Device}, Encoding),
            Encoding;
        Encoding ->
            Encoding
    end.

device_encoding(Device) ->
    case io:getopts(Device) of
        Options when is_list(Options) -> proplists:get_value(encoding, Options, latin1);
        _ -> unicode
    end.

%%% util.format

%% The line that `console.log(...args)` prints, without the newline.
-spec format(list()) -> binary().
format([Template | Args]) when is_binary(Template), Args =/= [] ->
    {Text, Rest} = substitute(Template, Args, []),
    join([Text | [display(Arg) || Arg <- Rest]]);
format(Args) ->
    join([display(Arg) || Arg <- Args]).

join(Parts) -> iolist_to_binary(lists:join($\s, Parts)).

display(S) when is_binary(S) -> S;
display(V) -> inspect(V).

substitute(<<"%", C, Rest/binary>>, [Arg | Args] = All, Acc) ->
    case specifier(C, Arg) of
        {ok, Text} -> substitute(Rest, Args, [Text | Acc]);
        percent -> substitute(Rest, All, [$% | Acc]);
        none -> substitute(<<C, Rest/binary>>, All, [$% | Acc])
    end;
substitute(<<"%%", Rest/binary>>, [], Acc) ->
    substitute(Rest, [], [$% | Acc]);
substitute(<<C, Rest/binary>>, Args, Acc) ->
    substitute(Rest, Args, [C | Acc]);
substitute(<<>>, Args, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Args}.

specifier($s, Arg) -> {ok, string_specifier(Arg)};
specifier($d, Arg) -> {ok, number_text(bouy_rt:to_number(Arg))};
specifier($i, Arg) -> {ok, number_text(bouy_number:'parseInt'([Arg]))};
specifier($f, Arg) -> {ok, number_text(bouy_number:'parseFloat'([Arg]))};
specifier($j, Arg) -> {ok, bouy_rt:to_string(bouy_json:stringify([Arg]))};
specifier($o, Arg) -> {ok, value(Arg, 0, 0, #ctx{depth = 4, hidden = true})};
specifier($O, Arg) -> {ok, inspect(Arg)};
specifier($c, _Arg) -> {ok, <<>>};
specifier($%, _Arg) -> percent;
specifier(_, _Arg) -> none.

string_specifier(N) when is_number(N) -> number_text(N);
string_specifier(#{<<"toString">> := F} = Object) when is_function(F, 1) -> bouy_rt:to_string(Object);
string_specifier(V) when is_list(V); is_map(V); is_tuple(V) -> inspect(V, 0);
string_specifier(V) -> bouy_rt:to_string(V).

%%% util.inspect

-spec inspect(term()) -> binary().
inspect(Value) -> inspect(Value, 2).

-spec inspect(term(), non_neg_integer()) -> binary().
inspect(Value, Depth) -> value(Value, 0, 0, #ctx{depth = Depth}).

%% Level counts the containers around the value, and Indent is the column
%% where the value's lines start after a line break.
value(S, _, _, _) when is_binary(S) -> string(S);
value(I, _, _, _) when is_integer(I) -> integer_to_binary(I);
value(F, _, _, _) when is_float(F) -> number_text(F);
value(A, _, _, _) when is_atom(A) -> atom_to_binary(A);
value(F, _, _, _) when is_function(F) -> function_label(F);
value(L, Level, Indent, Ctx) when is_list(L) -> array(L, Level, Indent, Ctx);
value(#{'$error' := _} = E, Level, Indent, Ctx) -> error_value(E, Level, Indent, Ctx);
value(M, Level, Indent, Ctx) when is_map(M) -> object(M, Level, Indent, Ctx);
value({'$map', _} = M, Level, Indent, Ctx) -> map(M, Level, Indent, Ctx);
value({'$set', _} = S, Level, Indent, Ctx) -> set(S, Level, Indent, Ctx);
value({'$iterator', Kind, Items}, Level, Indent, Ctx) -> iterator(Kind, Items, Level, Indent, Ctx);
value({'$date', _} = D, _, _, _) -> date(D);
value({'$class', _, Name}, _, _, _) -> <<"[class ", Name/binary, "]">>;
value({'$method', _, Name}, _, _, _) -> <<"[Function: ", Name/binary, "]">>;
value({'$prototype', {'$namespace', bouy_object}}, _, _, _) -> <<"[Object: null prototype] {}">>;
value({'$prototype', _}, _, _, _) -> <<"{}">>;
value({'$namespace', Module}, _, _, _) -> namespace(Module);
value({'$ref', Id}, _, _, _) -> <<"[ActorRef #", (integer_to_binary(Id))/binary, "]">>;
value({'$cast', Id}, _, _, _) -> <<"[ActorCast #", (integer_to_binary(Id))/binary, "]">>;
value({'$schedule', _}, _, _, _) -> <<"[Schedule]">>;
value({'$effect', _}, _, _, _) -> <<"[Effect]">>;
value({'$stream', _, _}, _, _, _) -> <<"Object [AsyncGenerator] {}">>;
value(Other, _, _, _) -> unicode:characters_to_binary(io_lib:format("~0tp", [Other])).

%% A string inside a value is quoted, and cut after maxStringLength UTF-16
%% code units.
string(S) ->
    case utf16_length(S) - ?MAX_STRING of
        Remaining when Remaining > 0 -> <<(quote(utf16_prefix(S, ?MAX_STRING)))/binary, (more(Remaining, <<"character">>))/binary>>;
        _ -> quote(S)
    end.

more(1, Noun) -> <<"... 1 more ", Noun/binary>>;
more(Count, Noun) -> <<"... ", (integer_to_binary(Count))/binary, " more ", Noun/binary, "s">>.

array([], _, _, #ctx{hidden = false}) ->
    <<"[]">>;
array(_, Level, _, #ctx{depth = Depth}) when Level > Depth ->
    <<"[Array]">>;
array(L, Level, Indent, Ctx) ->
    Shown = lists:sublist(L, ?MAX_ITEMS),
    Output = [value(Item, Level + 1, Indent + 2, Ctx) || Item <- Shown] ++ more_items(length(L)) ++ hidden_length(L, Ctx),
    reduce(group(Output, Shown, Indent), length(Output), <<>>, {<<"[">>, <<"]">>}, Indent).

hidden_length(L, #ctx{hidden = true}) -> [<<"[length]: ", (integer_to_binary(length(L)))/binary>>];
hidden_length(_L, _Ctx) -> [].

more_items(Length) when Length =< ?MAX_ITEMS -> [];
more_items(Length) -> [more(Length - ?MAX_ITEMS, <<"item">>)].

object(M, Level, Indent, Ctx) ->
    entries(bouy_object:own_entries(M), Level, Indent, Ctx).

entries([], _, _, _) ->
    <<"{}">>;
entries(_, Level, _, #ctx{depth = Depth}) when Level > Depth ->
    <<"[Object]">>;
entries(Pairs, Level, Indent, Ctx) ->
    Output = properties(Pairs, Level, Indent, Ctx),
    reduce(Output, length(Output), <<>>, {<<"{">>, <<"}">>}, Indent).

properties(Pairs, Level, Indent, Ctx) ->
    [<<(key(Key))/binary, ": ", (value(Value, Level + 1, Indent + 2, Ctx))/binary>> || {Key, Value} <- Pairs].

%% Own fields follow the message, and a cause prints as `[cause]`.
error_value(E, Level, Indent, Ctx) ->
    Fields = lists:sort(maps:to_list(bouy_error:fields(E))),
    Cause = [C || #{<<"cause">> := C} <- [E]],
    error_value(bouy_error:to_string(E), Fields, Cause, Level, Indent, Ctx).

error_value(Base, [], [], _, _, _) ->
    Base;
error_value(Base, _, _, Level, _, #ctx{depth = Depth}) when Level > Depth ->
    <<"[", Base/binary, "]">>;
error_value(Base, Fields, Cause, Level, Indent, Ctx) ->
    CauseEntries = [<<"[cause]: ", (value(C, Level + 1, Indent + 2, Ctx))/binary>> || C <- Cause],
    Output = properties(Fields, Level, Indent, Ctx) ++ CauseEntries,
    reduce(Output, length(Output), Base, {<<"{">>, <<"}">>}, Indent).

map(M, Level, Indent, Ctx) ->
    Format = fun({Key, Value}) ->
        <<(value(Key, Level + 1, Indent + 2, Ctx))/binary, " => ", (value(Value, Level + 1, Indent + 2, Ctx))/binary>>
    end,
    collection(<<"Map">>, bouy_map:entries(M), Format, Level, Indent, Ctx).

set(S, Level, Indent, Ctx) ->
    Format = fun(Item) -> value(Item, Level + 1, Indent + 2, Ctx) end,
    collection(<<"Set">>, bouy_set:items(S), Format, Level, Indent, Ctx).

collection(Name, [], _Format, _Level, _Indent, _Ctx) ->
    <<Name/binary, "(0) {}">>;
collection(Name, _Members, _Format, Level, _Indent, #ctx{depth = Depth}) when Level > Depth ->
    <<"[", Name/binary, "]">>;
collection(Name, Members, Format, _Level, Indent, _Ctx) ->
    Open = <<Name/binary, "(", (integer_to_binary(length(Members)))/binary, ") {">>,
    Output = [Format(Member) || Member <- lists:sublist(Members, ?MAX_ITEMS)] ++ more_items(length(Members)),
    reduce(Output, length(Output), <<>>, {Open, <<"}">>}, Indent).

%% Map and Set iterators show the items they have left; the others show
%% nothing, as Node prints them.
iterator(Kind, Items, Level, Indent, Ctx) when
    Kind =:= <<"Map Iterator">>; Kind =:= <<"Map Entries">>; Kind =:= <<"Set Iterator">>; Kind =:= <<"Set Entries">>
->
    Output = [value(Item, Level + 1, Indent + 2, Ctx) || Item <- lists:sublist(Items, ?MAX_ITEMS)] ++ more_items(length(Items)),
    reduce(Output, length(Output), <<>>, {<<"[", Kind/binary, "] {">>, <<"}">>}, Indent);
iterator(Kind, _Items, _Level, _Indent, _Ctx) ->
    <<"Object [", Kind/binary, "] {}">>.

%% Node's reduceToSingleString: one line when the entries fit in
%% breakLength and the array was not grouped, else one entry per line.
%% Lengths count UTF-16 code units, as in JavaScript.
reduce(Output, Entries, Base, {Open, Close}, Indent) ->
    Start = length(Output) + Indent + utf16_length(Open) + utf16_length(Base) + 10,
    case length(Output) =:= Entries andalso fits(Output, Start) of
        true -> iolist_to_binary([prefix(Base), Open, " ", lists:join(", ", Output), " ", Close]);
        false -> lines(Output, Base, Open, Close, Indent)
    end.

fits(Output, Start) ->
    Total = lists:sum([utf16_length(Entry) || Entry <- Output]) + length(Output) + Start,
    Total =< ?BREAK_LENGTH andalso not lists:any(fun has_newline/1, Output).

lines(Output, Base, Open, Close, Indent) ->
    Break = ["\n", lists:duplicate(Indent, $\s)],
    iolist_to_binary([prefix(Base), Open, Break, "  ", lists:join([",", Break, "  "], Output), Break, Close]).

prefix(<<>>) -> <<>>;
prefix(Base) -> <<Base/binary, " ">>.

has_newline(Text) -> binary:match(Text, <<"\n">>) =/= nomatch.

%% Node's groupArrayElements: more than six short entries line up in
%% columns, numbers aligned right and other values left. Widths are the
%% columns a terminal gives the text (getStringWidth).
group(Output, Items, Indent) when length(Output) > 6 ->
    Data = lists:sublist(Output, length(Items)),
    Widths = [width(Entry) || Entry <- Data],
    MaxLength = lists:max(Widths),
    TotalLength = lists:sum(Widths) + 2 * length(Data),
    ActualMax = MaxLength + 2,
    case ActualMax * 3 + Indent < ?BREAK_LENGTH andalso (TotalLength / ActualMax > 5 orelse MaxLength =< 6) of
        true -> columns(Output, Data, Widths, Items, Indent, ActualMax, TotalLength);
        false -> Output
    end;
group(Output, _Items, _Indent) ->
    Output.

columns(Output, Data, Widths, Items, Indent, ActualMax, TotalLength) ->
    AverageBias = math:sqrt(ActualMax - TotalLength / length(Output)),
    BiasedMax = max(ActualMax - 3 - AverageBias, 1),
    Columns = lists:min([
        round(math:sqrt(2.5 * BiasedMax * length(Data)) / BiasedMax),
        (?BREAK_LENGTH - Indent) div ActualMax,
        12,
        15
    ]),
    case Columns =< 1 of
        true -> Output;
        false -> rows(Data, Widths, Columns, alignment(Items)) ++ lists:nthtail(length(Data), Output)
    end.

alignment(Items) ->
    case lists:all(fun(Item) -> is_number(Item) orelse lists:member(Item, ['NaN', 'Infinity', '-Infinity']) end, Items) of
        true -> leading;
        false -> trailing
    end.

rows(Data, Widths, Columns, Align) ->
    ColumnWidths = [lists:max([W || {I, W} <- lists:enumerate(0, Widths), I rem Columns =:= C]) + 2 || C <- lists:seq(0, Columns - 1)],
    [row(Row, ColumnWidths, Align) || Row <- chunks(lists:zip(Data, Widths), Columns)].

row(Cells, ColumnWidths, Align) ->
    {Init, [{Last, LastWidth}]} = lists:split(length(Cells) - 1, Cells),
    LastColumn = lists:nth(length(Cells), ColumnWidths),
    Padded = [pad(<<Text/binary, ", ">>, Width + 2, ColumnWidth, Align) || {{Text, Width}, ColumnWidth} <- lists:zip(Init, lists:sublist(ColumnWidths, length(Init)))],
    iolist_to_binary([Padded, last_cell(Last, LastWidth, LastColumn, Align)]).

last_cell(Text, Width, ColumnWidth, leading) -> pad(Text, Width, ColumnWidth - 2, leading);
last_cell(Text, _Width, _ColumnWidth, trailing) -> Text.

pad(Text, Width, Target, _Align) when Width >= Target -> Text;
pad(Text, Width, Target, leading) -> [lists:duplicate(Target - Width, $\s), Text];
pad(Text, Width, Target, trailing) -> [Text, lists:duplicate(Target - Width, $\s)].

chunks([], _) -> [];
chunks(List, N) when length(List) =< N -> [List];
chunks(List, N) -> {Chunk, Rest} = lists:split(N, List), [Chunk | chunks(Rest, N)].

%%% Text widths

%% The length of a string in JavaScript: a code point outside the Basic
%% Multilingual Plane takes two UTF-16 code units.
utf16_length(Text) ->
    bouy_string:char_count(Text) + byte_size(<<<<C>> || <<C>> <= Text, C >= 16#F0>>).

%% The first Count UTF-16 code units, without splitting a surrogate pair.
utf16_prefix(Text, Count) ->
    binary:part(Text, 0, utf16_bytes(Text, Count, 0)).

utf16_bytes(Text, Count, Size) ->
    case Text of
        <<_:Size/binary, C/utf8, _/binary>> when C > 16#FFFF, Count >= 2 -> utf16_bytes(Text, Count - 2, Size + 4);
        <<_:Size/binary, C/utf8, _/binary>> when C =< 16#FFFF, Count >= 1 -> utf16_bytes(Text, Count - 1, Size + byte_size(<<C/utf8>>));
        _ -> Size
    end.

%% Node's getStringWidth: East Asian wide and fullwidth characters take two
%% columns, marks, format characters, and controls take none.
width(Text) ->
    lists:sum([char_width(C) || <<C/utf8>> <= Text]).

char_width(C) when C >= 16#20, C < 16#7F -> 1;
char_width(16#AD) -> 1;
char_width(C) when C >= 16#1F1E6, C =< 16#1F1FF -> 2;
char_width(C) ->
    case unicode_util:is_wide(C) of
        true -> 2;
        false -> narrow_width(unicode_util:category(C))
    end.

narrow_width({mark, non_spacing}) -> 0;
narrow_width({mark, enclosing}) -> 0;
narrow_width({other, format}) -> 0;
narrow_width({other, control}) -> 0;
narrow_width(_) -> 1.

%%% Leaves

number_text(F) when is_float(F), F == 0 ->
    case <<F/float>> of
        <<1:1, _:63>> -> <<"-0">>;
        _ -> <<"0">>
    end;
number_text(N) ->
    bouy_number:to_string(N).

-spec function_name(function()) -> binary().
function_name(F) ->
    {name, Name} = erlang:fun_info(F, name),
    case atom_to_binary(Name) of
        <<"-", _/binary>> -> <<>>;
        Text -> Text
    end.

function_label(F) ->
    case function_name(F) of
        <<>> -> <<"[Function (anonymous)]">>;
        Name -> <<"[Function: ", Name/binary, "]">>
    end.

date(Date) ->
    case bouy_date:call(<<"getTime">>, Date, []) of
        'NaN' -> <<"Invalid Date">>;
        _ -> bouy_date:call(<<"toISOString">>, Date, [])
    end.

namespace(Module) when Module =:= bouy_math; Module =:= bouy_json; Module =:= bouy_console ->
    <<"Object [", (bouy_rt:global_name(Module))/binary, "] {}">>;
namespace(Module) ->
    case bouy_rt:global_name(Module) of
        undefined -> <<"[Module: ", (atom_to_binary(Module))/binary, "]">>;
        Name -> <<"[Function: ", Name/binary, "]">>
    end.

%% Object keys that are identifiers print bare, others quoted. Node quotes
%% `__proto__`, because a bare `__proto__` in a literal sets the prototype.
key(<<"__proto__">>) -> <<"['__proto__']">>;
key(Key) ->
    case is_identifier(Key) of
        true -> Key;
        false -> quote(Key)
    end.

is_identifier(<<C, Rest/binary>>) when C =:= $_; C >= $a, C =< $z; C >= $A, C =< $Z -> is_identifier_rest(Rest);
is_identifier(_) -> false.

is_identifier_rest(<<C, Rest/binary>>) when C =:= $_; C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 ->
    is_identifier_rest(Rest);
is_identifier_rest(<<>>) ->
    true;
is_identifier_rest(_) ->
    false.

%% Node's strEscape: single quotes unless the string holds one, then
%% double quotes, then backticks, then escaped single quotes.
quote(S) ->
    Quote = quote_char(S),
    iolist_to_binary([Quote, [escape(C, Quote) || <<C/utf8>> <= S], Quote]).

quote_char(S) ->
    case {has(S, <<"'">>), has(S, <<"\"">>), has(S, <<"`">>) orelse has(S, <<"${">>)} of
        {false, _, _} -> $';
        {true, false, _} -> $";
        {true, true, false} -> $`;
        {true, true, true} -> $'
    end.

has(S, Pattern) -> binary:match(S, Pattern) =/= nomatch.

escape($', $') -> <<"\\'">>;
escape($\\, _) -> <<"\\\\">>;
escape($\b, _) -> <<"\\b">>;
escape($\t, _) -> <<"\\t">>;
escape($\n, _) -> <<"\\n">>;
escape($\f, _) -> <<"\\f">>;
escape($\r, _) -> <<"\\r">>;
escape(C, _) when C < 16#20; C >= 16#7F, C =< 16#9F -> io_lib:format("\\x~2.16.0B", [C]);
escape(C, _) -> <<C/utf8>>.
