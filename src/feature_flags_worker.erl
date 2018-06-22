-module(feature_flags_worker).
-behaviour(gen_server).

%% API functions.
-export([start_link/0]).

%% gen_server callbacks.
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(FEATURE_FLAGS_V1, [v1]).
-define(FEATURE_FLAGS_V2, ?FEATURE_FLAGS_V1 ++ [v2]).

-record(state, {
          supported = [] :: [atom()],
          enabled = [] :: [atom()],
          run_timer = undefined
         }).
-type state() :: #state{}.

%% -------------------------------------------------------------------
%% API functions.
%% -------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% -------------------------------------------------------------------
%% gen_server callbacks.
%% -------------------------------------------------------------------

-spec init(term()) -> {ok, state()}.
init([]) ->
    Supported = case application:get_env(proto) of
                    {ok, v1} -> ?FEATURE_FLAGS_V1;
                    {ok, v2} -> ?FEATURE_FLAGS_V2
                end,
    State0 = #state{supported = Supported},
    case is_local_node_compatible_with_remote_nodes(State0) of
        true ->
            {_, State1} = enable_all(State0),
            log_feature_flags(State1),
            {ok, TRef} = timer:apply_interval(1000, gen_server, cast, [?MODULE, run]),
            State2 = State1#state{run_timer = TRef},
            {ok, State2};
        false ->
            {stop, enabled_features_unsupported}
    end.

handle_call(supported, _From, #state{supported = Supported} = State) ->
    {reply, Supported, State};

handle_call(enabled, _From, #state{enabled = Enabled} = State) ->
    {reply, Enabled, State};

handle_call({is_supported, Flag}, _From, State) ->
    {reply, is_supported(Flag, State), State};

handle_call(enable_all, _From, State) ->
    {Reply, State1} = enable_all(State),
    {reply, Reply, State1};

handle_call({enable, Flag}, _From, State) ->
    {Reply, State1} = enable([Flag], State),
    {reply, Reply, State1};

handle_call(_, _From, State) ->
    {reply, undefined, State}.

handle_cast(list, State) ->
    log_feature_flags(State),
    {noreply, State};

handle_cast({try_enable, Flag}, State) ->
    {_, State1} = enable([Flag], State),
    {noreply, State1};

handle_cast(run, State) ->
    run(State),
    {noreply, State};

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{run_timer = TRef} = _State) ->
    timer:cancel(TRef),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------------------

all_flags(#state{supported = Supported}) ->
    Supported.

is_supported(Flag, #state{supported = Supported}) ->
    lists:member(Flag, Supported).

is_enabled(Flag, #state{enabled = Enabled}) ->
    lists:member(Flag, Enabled).

enable_all(State) ->
    AllFlags = all_flags(State),
    enable(AllFlags, State).

enable([Flag | Rest], State) ->
    case enable_one(Flag, State) of
        {ok, State1}    -> enable(Rest, State1);
        {Error, State1} -> {Error, State1}
    end;
enable([], State) ->
    {ok, State}.

enable_one(Flag, State) ->
    case is_enabled(Flag, State) of
        true ->
            {ok, State};
        false ->
            case is_supported(Flag, State) of
                true  -> try_to_enable(Flag, State);
                false -> {{error, {unsupported, Flag}}, State}
            end
    end.

try_to_enable(Flag, State) ->
    case are_remote_nodes_compatible(Flag, State) of
        true  -> do_enable(Flag, State);
        false -> {{error, incomptible_with_cluster}, State}
    end.

are_remote_nodes_compatible(Flag, State) ->
    Nodes = nodes(),
    are_remote_nodes_compatible(Nodes, Flag, State).

are_remote_nodes_compatible(Nodes, Flag, _State) ->
    Result = [{Node,
               try
                   gen_server:call({?MODULE, Node}, {is_supported, Flag})
               catch
                   exit:{noproc, _} -> down
               end}
              || Node <- Nodes],
    io:format("Feature flag '~s' supported on remote nodes:~n~s~n",
              [Flag, [io_lib:format("  ~s: ~p~n", [Node, Supported])
                      || {Node, Supported} <- Result]]),
    lists:all(fun({_, I}) -> I =:= true orelse I =:= down end, Result).

is_local_node_compatible_with_remote_nodes(State) ->
    Nodes = nodes(),
    is_local_node_compatible_with_remote_nodes(Nodes, State).

is_local_node_compatible_with_remote_nodes(Nodes, #state{supported = Supported}) ->
    Result = [{Node,
               try
                   RemotelyEnabled = gen_server:call({?MODULE, Node}, enabled),
                   RemotelyEnabled -- Supported
               catch
                   exit:{noproc, _} -> down
               end}
              || Node <- Nodes],
    io:format("Unsupported feature flags enabled on remote nodes:~n~s~n",
              [[io_lib:format("  ~s: ~p~n", [Node, Unsupported])
                || {Node, Unsupported} <- Result, Unsupported =/= []]]),
    lists:all(fun({_, I}) -> I =:= [] orelse I =:= down end, Result).

do_enable(Flag, #state{enabled = Enabled} = State) ->
    Enabled1 = Enabled ++ [Flag],
    State1 = State#state{enabled = Enabled1},
    log_feature_flags(State1),
    [gen_server:cast({?MODULE, Node}, {try_enable, Flag}) || Node <- nodes()],
    {ok, State1}.

log_feature_flags(#state{supported = Supported} = State) ->
    log_feature_flags1(Supported, State, []).

log_feature_flags1([Flag | Rest], State, Lines) ->
    Line = case is_enabled(Flag, State) of
               true  -> io_lib:format("  \033[1;32m[x] ~s\033[0m~n", [Flag]);
               false -> io_lib:format("  [ ] ~s~n", [Flag])
           end,
    log_feature_flags1(Rest, State, [Line | Lines]);
log_feature_flags1([], _, Lines) ->
    io:format("Feature flags:~n~s~n", [lists:reverse(Lines)]).

run(State) ->
    case is_enabled(v2, State) of
        true  -> io:format("Running \033[1;32mV2\033[0m code...~n", []);
        false -> io:format("Running \033[1;33mV1\033[0m code...~n", [])
    end.
