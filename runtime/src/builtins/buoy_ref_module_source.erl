%% %AbstractModuleSource% (the source phase imports proposal, stage 3): the
%% abstract class of the module source objects that `import source` gives, such
%% as a WebAssembly.Module. It is not a global; a host reaches it through the
%% prototype of a module source class, and the test262 runner through
%% `$262.AbstractModuleSource`. Its constructor always throws, and its
%% @@toStringTag getter answers the [[ModuleSourceClassName]] of a module
%% source object: "WebAssembly.Module" for a WebAssembly module, the only
%% module source of Buoy, else undefined.
-module(buoy_ref_module_source).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [record/4, ctor_record/5]).
-import(buoy_ref, [type_error/1]).

-define(PROTO, 'AbstractModuleSource.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Tag = {'$accessor', buoy_ref_realm:builtin(<<"get AbstractModuleSource.prototype[Symbol.toStringTag]">>, <<"get [Symbol.toStringTag]">>, 0,
                                               fun(This, _) -> class_name(This) end), undefined},
    [{?PROTO, record(object, ?OBJECT_PROTO, [{<<"constructor">>, constructor()}, {?SYM(toStringTag), Tag, 4}], none)},
     {{builtin, <<"AbstractModuleSource">>}, ctor_record(<<"AbstractModuleSource">>, 0, {'$o', ?PROTO}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"AbstractModuleSource">>).

-spec method(binary(), binary(), term(), list()) -> no_return().
method(_Owner, Name, _This, _Args) -> type_error(<<"AbstractModuleSource has no method ", Name/binary>>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> type_error(<<"Constructor AbstractModuleSource requires 'new'">>).

-spec construct(term(), list()) -> no_return().
construct(_NewTarget, _Args) -> type_error(<<"AbstractModuleSource is an abstract class">>).

class_name(O) when ?IS_OBJECT(O) ->
    case buoy_heap:class_of(O) of
        wasm_module -> <<"WebAssembly.Module">>;
        _ -> undefined
    end;
class_name(_) -> undefined.
