-module(feature_flags_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    feature_flags_sup:start_link().

stop(_State) ->
    ok.
