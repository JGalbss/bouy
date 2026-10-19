%% internalBinding('modules') (src/node_modules.cc): the package.json reader of
%% Node's module loaders, which keeps each file it read, or found missing, for
%% the life of the process, as the BindingData of Node keeps it per realm. Buoy
%% has no V8 code cache, so the compile cache stays off, as it is in Node until
%% NODE_COMPILE_CACHE or module.enableCompileCache turns it on.
-module(buoy_binding_modules).

-include("buoy_ref.hrl").

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"readPackageJSON">>, F(<<"readPackageJSON">>, 0, fun(_, A) -> read_package_json(A) end)},
        {<<"getNearestParentPackageJSONType">>, F(<<"getNearestParentPackageJSONType">>, 0, fun(_, A) ->
            type_of(nearest_parent(path_arg(A)))
        end)},
        {<<"getNearestParentPackageJSON">>, F(<<"getNearestParentPackageJSON">>, 0, fun(_, A) ->
            serialize(nearest_parent(path_arg(A)))
        end)},
        {<<"getPackageScopeConfig">>, F(<<"getPackageScopeConfig">>, 0, fun(_, A) ->
            case package_scope(buoy_node:arg(1, A)) of
                {found, Config} -> serialize(Config);
                {missing, Last} -> buoy_node:string(Last)
            end
        end)},
        {<<"getPackageType">>, F(<<"getPackageType">>, 0, fun(_, A) ->
            case package_scope(buoy_node:arg(1, A)) of
                {found, Config} -> type_of(Config);
                {missing, _} -> undefined
            end
        end)},
        {<<"getCompileCacheDir">>, F(<<"getCompileCacheDir">>, 0, fun(_, _) -> <<>> end)},
        {<<"flushCompileCache">>, F(<<"flushCompileCache">>, 0, fun(_, A) -> flush_compile_cache(buoy_node:arg(1, A)) end)},
        {<<"getCompileCacheEntry">>, F(<<"getCompileCacheEntry">>, 0, fun(_, _) -> undefined end)},
        {<<"compileCacheStatus">>, buoy_heap:new_array([<<"FAILED">>, <<"ENABLED">>, <<"ALREADY_ENABLED">>, <<"DISABLED">>])},
        {<<"cachedCodeTypes">>, buoy_heap:object(null, [{<<"kCommonJS">>, 0}, {<<"kESM">>, 1}, {<<"kStrippedTypeScript">>, 2},
                                                        {<<"kTransformedTypeScript">>, 3}, {<<"kTransformedTypeScriptWithSourceMaps">>, 4}])},
        {<<"moduleFormats">>, buoy_heap:object(null, [{<<"kCommonJS">>, 0}, {<<"kModule">>, 1}])}
    ]).

%% readPackageJSON(path, isESM, base, specifier): the config of the file, or
%% undefined when it does not exist. An ESM read names the import in the error
%% of a file that is no JSON object.
read_package_json(Args) ->
    Path = utf8(buoy_node:arg(1, Args)),
    Context = case buoy_node:arg(2, Args) of
        true -> {utf8_or_none(buoy_node:arg(3, Args)), utf8(buoy_node:arg(4, Args))};
        _ -> none
    end,
    serialize(package_json(Path, Context)).

%% The package.json of the nearest directory above Path, as TraverseParent
%% walks: from the directory of Path, or Path itself when it ends with a
%% slash, up to a node_modules directory, never reading the root.
nearest_parent(Path) -> nearest_from(start_directory(Path)).

%% The directory that a walk starts from: Path itself when it ends with a
%% slash, else the directory of Path.
start_directory(Path) ->
    case string:trim(Path, trailing, "/") of
        Path -> filename:dirname(Path);
        <<>> -> <<"/">>;
        Directory -> Directory
    end.

nearest_from(Directory) ->
    Done = filename:dirname(Directory) =:= Directory orelse filename:basename(Directory) =:= <<"node_modules">>,
    case Done of
        true -> missing;
        false ->
            case package_json(filename:join(Directory, <<"package.json">>), none) of
                missing -> nearest_from(filename:dirname(Directory));
                Config -> Config
            end
    end.

%% The package scope of a resolved file URL, as GetPackageScopeConfig walks:
%% each package.json from the directory of the URL up to the root, stopping
%% below a node_modules directory. {missing, Path} names the last file it
%% tried.
package_scope(Resolved) ->
    Url = utf8(Resolved),
    case uri_string:parse(Url) of
        #{scheme := <<"file">>, path := Encoded} when Encoded =/= <<>> ->
            scope_from(start_directory(uri_string:percent_decode(Encoded)), Url);
        _ ->
            buoy_node:throw_code('TypeError', <<"ERR_INVALID_URL">>, <<"Invalid URL">>)
    end.

scope_from(Directory, Url) ->
    File = filename:join(Directory, <<"package.json">>),
    Parent = filename:dirname(Directory),
    case filename:basename(Directory) =:= <<"node_modules">> of
        true -> {missing, File};
        false ->
            case package_json(File, {none, Url}) of
                missing when Parent =:= Directory -> {missing, File};
                missing -> scope_from(Parent, Url);
                Config -> {found, Config}
            end
    end.

%% The config of the package.json at Path, from the cache of this process. A
%% missing file stays missing; a file that is no JSON object throws on each
%% read, as GetPackageJSON caches only what it parsed.
package_json(Path, Context) ->
    Key = {?MODULE, Path},
    case erlang:get(Key) of
        undefined ->
            Config = case file:read_file(Path) of
                {ok, Text} -> parse(Path, Text, Context);
                {error, _} -> missing
            end,
            erlang:put(Key, Config),
            Config;
        Config ->
            Config
    end.

parse(Path, Text, Context) ->
    Json = case Text of
        <<16#EF, 16#BB, 16#BF, Rest/binary>> -> Rest;
        _ -> Text
    end,
    Object = try buoy_ref_json:parse(buoy_ref_string:from_utf8(Json))
             catch error:{'$throw', _} -> invalid(Path, Context)
             end,
    case buoy_heap:is_object(Object) andalso not buoy_ref_array:is_array(Object) of
        true -> config(Path, Object, Context);
        false -> invalid(Path, Context)
    end.

%% The fields that Node keeps: a name that is no string and a type that is no
%% string make the file invalid; a main that is no string, and exports and
%% imports that are neither strings, objects, nor arrays, count as absent.
config(Path, Object, Context) ->
    Field = fun(Key) -> buoy_heap:get(Object, Key) end,
    Name = case Field(<<"name">>) of
        undefined -> undefined;
        N -> string_or_invalid(N, Path, Context)
    end,
    Type = case Field(<<"type">>) of
        undefined -> <<"none">>;
        T ->
            case utf8(string_or_invalid(T, Path, Context)) of
                Known when Known =:= <<"commonjs">>; Known =:= <<"module">> -> Known;
                _ -> <<"none">>
            end
    end,
    Main = case Field(<<"main">>) of
        M when ?IS_STRING(M) -> M;
        _ -> undefined
    end,
    #{name => Name, main => Main, type => Type, imports => raw(Field(<<"imports">>)),
      exports => raw(Field(<<"exports">>)), path => Path}.

string_or_invalid(Value, _Path, _Context) when ?IS_STRING(Value) -> Value;
string_or_invalid(_, Path, Context) -> invalid(Path, Context).

%% A string as it is; an object or an array as its JSON text, which the loader
%% parses when it reads the field.
raw(Value) when ?IS_STRING(Value) -> Value;
raw(Value) ->
    case buoy_heap:is_object(Value) of
        true -> buoy_ref_json:stringify(Value, undefined, undefined);
        false -> undefined
    end.

-spec invalid(binary(), term()) -> no_return().
invalid(Path, {Base, Specifier}) when is_binary(Base) ->
    From = case uri_string:parse(Base) of
        #{scheme := <<"file">>, path := Encoded} -> uri_string:percent_decode(Encoded);
        _ -> Base
    end,
    buoy_node:throw_code('Error', <<"ERR_INVALID_PACKAGE_CONFIG">>,
                         iolist_to_binary(["Invalid package config ", Path, " while importing \"", Specifier, "\" from ", From, "."]));
invalid(Path, _) ->
    buoy_node:throw_code('Error', <<"ERR_INVALID_PACKAGE_CONFIG">>, iolist_to_binary(["Invalid package config ", Path, "."])).

%% PackageConfig::Serialize: [name, main, type, imports, exports, path].
serialize(missing) -> undefined;
serialize(#{name := Name, main := Main, type := Type, imports := Imports, exports := Exports, path := Path}) ->
    buoy_heap:new_array([Name, Main, buoy_node:string(Type), Imports, Exports, buoy_node:string(Path)]).

type_of(missing) -> undefined;
type_of(#{type := Type}) -> buoy_node:string(Type).

flush_compile_cache(Keep) when is_boolean(Keep); Keep =:= undefined -> undefined;
flush_compile_cache(_) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"keepDeserializedCache should be a boolean">>).

path_arg(Args) -> utf8(buoy_node:arg(1, Args)).

utf8_or_none(Value) when ?IS_STRING(Value) -> utf8(Value);
utf8_or_none(_) -> none.

utf8(Value) -> buoy_ref_string:to_utf8(buoy_ref:to_string(Value)).
