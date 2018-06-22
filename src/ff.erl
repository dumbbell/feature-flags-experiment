-module(ff).

-export([start/0,
         start/1,
         stop/0,
         list/0,
         enable/1,
         enable_all/0,
         run/0]).

-define(APP, feature_flags).
-define(SERVER, feature_flags_worker).

start() ->
    start(v1).

start(Proto) ->
    application:load(?APP),
    application:set_env(?APP, proto, Proto),
    application:start(?APP).

stop() ->
    application:stop(?APP).

list() ->
    gen_server:cast(?SERVER, list).

enable(Flag) ->
    gen_server:call(?SERVER, {enable, Flag}).

enable_all() ->
    gen_server:call(?SERVER, enable_all).

run() ->
    gen_server:cast(?SERVER, run).
