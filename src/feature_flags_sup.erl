-module(feature_flags_sup).
-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Worker = #{
      id => feature_flags_worker,
      start => {feature_flags_worker, start_link, []}
     },
    {ok, {{one_for_one, 1, 5}, [Worker]}}.
