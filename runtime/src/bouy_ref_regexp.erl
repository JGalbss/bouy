%% The RegExp family. RegExp has no implementation yet.
-module(bouy_ref_regexp).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0]).


-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()}].
globals() -> [].
