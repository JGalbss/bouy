%% internalBinding('modules') (src/node_modules.cc): the package.json reader of
%% the module loaders, and the compile cache of node:module. A package.json is
%% read once per realm and kept, as Node keeps it in its binding data. The
%% serialized form is Node's: [name, main, type, imports, exports, path], with
%% imports and exports as their JSON text when they are an object or an array.
-module(buoy_binding_modules).

-export([binding/0]).

-include("buoy_ref.hrl").

-define(CACHE(Path), {?MODULE, package, Path}).
-define(COMPILE_CACHE, {?MODULE, compile_cache}).

%% The fields of a package.json that the loaders read.
-record(package, {name, main, type = <<"none">>, imports, exports, path}).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    buoy_node:object([
        {<<"readPackageJSON">>, F(<<"readPackageJSON">>, 4, fun(_, Args) -> read_package_json(Args) end)},
        {<<"getNearestParentPackageJSON">>, F(<<"getNearestParentPackageJSON">>, 1, fun(_, Args) ->
            serialize(nearest_parent(path_of(A(1, Args))))
        end)},
        {<<"getNearestParentPackageJSONType">>, F(<<"getNearestParentPackageJSONType">>, 1, fun(_, Args) ->
            case nearest_parent(path_of(A(1, Args))) of
                none -> undefined;
                Package -> Package#package.type
            end
        end)},
        {<<"getPackageScopeConfig">>, F(<<"getPackageScopeConfig">>, 1, fun(_, Args) ->
            case package_scope(A(1, Args)) of
                {found, Package} -> serialize(Package);
                {missing, Path} -> buoy_node:string(Path)
            end
        end)},
        {<<"getPackageType">>, F(<<"getPackageType">>, 1, fun(_, Args) ->
            case package_scope(A(1, Args)) of
                {found, Package} -> Package#package.type;
                {missing, _} -> undefined
            end
        end)},
        {<<"enableCompileCache">>, F(<<"enableCompileCache">>, 2, fun(_, Args) -> enable_compile_cache(A(1, Args)) end)},
        {<<"getCompileCacheDir">>, F(<<"getCompileCacheDir">>, 0, fun(_, _) ->
            case erlang:get(?COMPILE_CACHE) of
                undefined -> <<>>;
                Directory -> Directory
            end
        end)},
        {<<"flushCompileCache">>, F(<<"flushCompileCache">>, 1, fun(_, Args) -> flush_compile_cache(A(1, Args)) end)},
        {<<"getCompileCacheEntry">>, F(<<"getCompileCacheEntry">>, 4, fun(_, _) -> undefined end)},
        {<<"saveCompileCacheEntry">>, F(<<"saveCompileCacheEntry">>, 2, fun(_, _) -> undefined end)},
        {<<"compileCacheStatus">>, buoy_heap:new_array([<<"FAILED">>, <<"ENABLED">>, <<"ALREADY_ENABLED">>, <<"DISABLED">>])},
        {<<"cachedCodeTypes">>, buoy_node:object([{<<"kCommonJS">>, 0}, {<<"kESM">>, 1}, {<<"kStrippedTypeScript">>, 2},
                                                  {<<"kTransformedTypeScript">>, 3},
                                                  {<<"kTransformedTypeScriptWithSourceMaps">>, 4}])},
        {<<"moduleFormats">>, buoy_node:object([{<<"kCommonJS">>, 0}, {<<"kModule">>, 1}])}]).

path_of(Value) -> buoy_ref_string:to_utf8(Value).

%% readPackageJSON(path, isESM, base, specifier): the serialized package, or
%% undefined when the file cannot be read.
read_package_json(Args) ->
    Path = path_of(buoy_node:arg(1, Args)),
    Context = case buoy_node:arg(2, Args) of
        true -> {buoy_node:arg(3, Args), buoy_node:arg(4, Args)};
        _ -> none
    end,
    serialize(package(Path, Context)).

serialize(none) ->
    undefined;
serialize(#package{name = Name, main = Main, type = Type, imports = Imports, exports = Exports, path = Path}) ->
    buoy_heap:new_array([Name, Main, Type, Imports, Exports, buoy_node:string(Path)]).

%% The package.json at Path, or none when it cannot be read. Context is the
%% {base, specifier} of an ES module import, which an invalid file names.
package(Path, Context) ->
    case erlang:get(?CACHE(Path)) of
        undefined ->
            Package = case file:read_file(Path) of
                {ok, Text} -> parse(Path, Text, Context);
                {error, _} -> none
            end,
            erlang:put(?CACHE(Path), Package),
            Package;
        Cached ->
            Cached
    end.

parse(Path, <<16#EF, 16#BB, 16#BF, Text/binary>>, Context) ->
    parse(Path, Text, Context);
parse(Path, Text, Context) ->
    Pairs = try buoy_node_json_pairs(Text) of
        {pairs, P} -> P;
        _ -> invalid(Path, Context)
    catch
        error:_ -> invalid(Path, Context)
    end,
    lists:foldl(fun({Key, Value}, Package) -> field(Key, Value, Package, Path, Context) end,
                #package{path = Path}, Pairs).

%% The JSON text as nested {pairs, [{Key, Value}]} objects in source order,
%% since the order of the conditions of exports matters.
buoy_node_json_pairs(Text) ->
    Push = fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
    Finish = fun(Acc, Old) -> {{pairs, lists:reverse(Acc)}, Old} end,
    {Term, ok, Rest} = json:decode(Text, ok, #{object_push => Push, object_finish => Finish}),
    <<>> = string:trim(Rest),
    Term.

%% The fields of node_modules.cc: a name that is no string makes the file
%% invalid, a main that is no string is left out, and exports and imports keep
%% their JSON text when they are an object or an array.
field(<<"name">>, Name, Package, _, _) when is_binary(Name) -> Package#package{name = buoy_node:string(Name)};
field(<<"name">>, _, _, Path, Context) -> invalid(Path, Context);
field(<<"main">>, Main, Package, _, _) when is_binary(Main) -> Package#package{main = buoy_node:string(Main)};
field(<<"main">>, _, Package, _, _) -> Package;
field(<<"exports">>, Value, Package, _, _) -> Package#package{exports = raw(Value)};
field(<<"imports">>, Value, Package, _, _) -> Package#package{imports = raw(Value)};
field(<<"type">>, Type, Package, _, _) when Type =:= <<"commonjs">>; Type =:= <<"module">> -> Package#package{type = Type};
field(<<"type">>, Type, Package, _, _) when is_binary(Type) -> Package;
field(<<"type">>, _, _, Path, Context) -> invalid(Path, Context);
field(_, _, Package, _, _) -> Package.

raw(Value) when is_binary(Value) -> buoy_node:string(Value);
raw({pairs, _} = Value) -> buoy_node:string(iolist_to_binary(encode(Value)));
raw(Value) when is_list(Value) -> buoy_node:string(iolist_to_binary(encode(Value)));
raw(_) -> undefined.

encode({pairs, Pairs}) -> [${, lists:join($,, [[json:encode(K), $:, encode(V)] || {K, V} <- Pairs]), $}];
encode(List) when is_list(List) -> [$[, lists:join($,, [encode(V) || V <- List]), $]];
encode(Value) -> json:encode(Value).

-spec invalid(binary(), none | {term(), term()}) -> no_return().
invalid(Path, {Base, Specifier}) when Base =/= undefined ->
    buoy_node:throw_code('Error', <<"ERR_INVALID_PACKAGE_CONFIG">>,
                         iolist_to_binary(["Invalid package config ", Path, " while importing \"",
                                           path_of(Specifier), "\" from ", file_path(path_of(Base)), "."]));
invalid(Path, _) ->
    buoy_node:throw_code('Error', <<"ERR_INVALID_PACKAGE_CONFIG">>, iolist_to_binary(["Invalid package config ", Path, "."])).

%% TraverseParent: the package.json of the nearest directory above Path that
%% has one, short of a node_modules directory and of the root.
nearest_parent(Path) ->
    traverse(filename:dirname(Path)).

traverse(Directory) ->
    case filename:dirname(Directory) =:= Directory orelse filename:basename(Directory) =:= <<"node_modules">> of
        true ->
            none;
        false ->
            case package(filename:join(Directory, <<"package.json">>), none) of
                none -> traverse(filename:dirname(Directory));
                Package -> Package
            end
    end.

%% GetPackageScopeConfig: the package.json of the nearest directory of the
%% file URL Resolved, up to a node_modules directory or the root, or the path
%% where the search ended.
package_scope(Resolved) ->
    Url = path_of(Resolved),
    Path = case Url of
        <<"file://", _/binary>> -> file_path(Url);
        _ -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_URL">>, <<"Invalid URL">>)
    end,
    Start = case binary:last(Path) of
        $/ -> Path;
        _ -> filename:dirname(Path)
    end,
    scope(Start, Url).

scope(Directory, Url) ->
    Candidate = case Directory of
        <<"/">> -> <<"/package.json">>;
        _ -> <<Directory/binary, "/package.json">>
    end,
    case binary:longest_common_suffix([Candidate, <<"/node_modules/package.json">>]) =:= 26 of
        true ->
            {missing, Candidate};
        false ->
            case package(Candidate, {undefined, Url}) of
                none when Directory =:= <<"/">> -> {missing, Candidate};
                none -> scope(filename:dirname(Directory), Url);
                Package -> {found, Package}
            end
    end.

%% fileURLToPath of a file URL: the path, percent-decoded.
file_path(<<"file://", Rest/binary>>) ->
    Path = hd(binary:split(Rest, [<<"?">>, <<"#">>])),
    uri_string:percent_decode(Path);
file_path(Path) ->
    Path.

%%% The compile cache of node:module. Buoy keeps every compiled module in its
%%% own cache (~/.cache/buoy), so enableCompileCache records the directory and
%%% reports the cache as enabled.

enable_compile_cache(Directory) when ?IS_STRING(Directory) ->
    {Status, Message} = case erlang:get(?COMPILE_CACHE) of
        undefined -> {1, undefined};
        _ -> {2, buoy_node:string(<<"Already enabled">>)}
    end,
    Status =:= 1 andalso erlang:put(?COMPILE_CACHE, Directory),
    buoy_heap:new_array([Status, Message, erlang:get(?COMPILE_CACHE)]);
enable_compile_cache(_) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"cacheDir should be a string">>).

flush_compile_cache(Keep) when is_boolean(Keep); Keep =:= undefined -> undefined;
flush_compile_cache(_) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"keepDeserializedCache should be a boolean">>).
