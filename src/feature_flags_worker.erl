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
    State = #state{supported = Supported},
    %% 1. To start, a node must support all features enabled in the cluster.
    %% 2. It must then enable all features enabled elsewhere.
    RemotelyEnabledPerNode = query_enabled_feature_flags_on_remote_nodes(
                               State),
    case are_remote_feature_flags_supported(RemotelyEnabledPerNode, State) of
        true ->
            ToEnable = case RemotelyEnabledPerNode of
                           [] -> Supported;
                           _  -> sumup_remote_feature_flags(
                                   RemotelyEnabledPerNode)
                       end,
            case enable_feature_flags(ToEnable, State) of
                {ok, State1} ->
                    {ok, State1};
                {Error, _State1} ->
                    {stop, {failed_to_enable_feature_flags, Error}}
            end;
        false ->
            {stop, incompatible_with_remote_nodes}
    end.

handle_call(supported, _From, #state{supported = Supported} = State) ->
    {reply, Supported, State};

handle_call(enabled, _From, #state{enabled = Enabled} = State) ->
    {reply, Enabled, State};

handle_call({is_supported, Flag}, _From, State) ->
    {reply, is_supported(Flag, State), State};

handle_call(enable_all_feature_flags, _From, State) ->
    {Reply, State1} = enable_all_feature_flags(State),
    {reply, Reply, State1};

handle_call({enable, Flag}, _From, State) ->
    {Reply, State1} = enable_feature_flags([Flag], State),
    {reply, Reply, State1};

handle_call({enable_locally, Flag}, _From, State) ->
    {Reply, State1} = enable_feature_flag_locally(Flag, State),
    {reply, Reply, State1};

handle_call({query_feature_flags, supported}, _From,
            #state{supported = Supported} = State) ->
    {reply, Supported, State};

handle_call({query_feature_flags, enabled}, _From,
            #state{enabled = Enabled} = State) ->
    {reply, Enabled, State};

handle_call(_, _From, State) ->
    {reply, undefined, State}.

handle_cast(list, State) ->
    log_feature_flags(State),
    {noreply, State};

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

all_feature_flags(#state{supported = Supported}) ->
    Supported.

is_supported(Flag, #state{supported = Supported}) ->
    lists:member(Flag, Supported).

is_enabled(Flag, #state{enabled = Enabled}) ->
    lists:member(Flag, Enabled).

enable_all_feature_flags(State) ->
    AllFlags = all_feature_flags(State),
    enable_feature_flags(AllFlags, State).

enable_feature_flags([Flag | Rest], State) ->
    case enable_feature_flag(Flag, State) of
        {ok, State1}    -> enable_feature_flags(Rest, State1);
        {Error, State1} -> {Error, State1}
    end;
enable_feature_flags([], State) ->
    {ok, State}.

enable_feature_flag(Flag, State) ->
    Nodes = participating_nodes(State),
    case are_remote_nodes_compatible(Nodes, Flag, State) of
        true -> enable_feature_flag(Nodes, Flag, State);
        false -> {{error, {incompatible_with_remote_nodes, Flag}}, State}
    end.

enable_feature_flag([Node | Rest], Flag, State) ->
    case gen_server:call({?MODULE, Node}, {enable_locally, Flag}) of
        ok    -> enable_feature_flag(Rest, Flag, State);
        Error -> {Error, State}
    end;
enable_feature_flag([], Flag, State) ->
    enable_feature_flag_locally(Flag, State).

enable_feature_flag_locally(Flag, State) ->
    case is_enabled(Flag, State) of
        true ->
            {ok, State};
        false ->
            case is_supported(Flag, State) of
                true  -> do_enable(Flag, State);
                false -> {{error, {unsupported, Flag}}, State}
            end
    end.

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

do_enable(Flag, #state{enabled = Enabled} = State) ->
    case try_to_enable_deps(Flag, State) of
        {ok, State1} ->
            Enabled1 = Enabled ++ [Flag],
            State2 = State1#state{enabled = Enabled1},
            log_feature_flags(State2),
            {ok, State2};
        {Error, State1} ->
            {Error, State1}
    end.

try_to_enable_deps(v1, State) ->
    {ok, State};
try_to_enable_deps(v2, State) ->
    enable_feature_flag_locally(v1, State).

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

%% -------------------------------------------------------------------

%query_supported_feature_flags_on_remote_nodes(#state{} = State) ->
%    Nodes = participating_nodes(State),
%    query_supported_feature_flags_on_nodes(Nodes).
%
%query_supported_feature_flags_on_nodes(Nodes) ->
%    query_feature_flags_on_nodes(Nodes, supported).

query_enabled_feature_flags_on_remote_nodes(#state{} = State) ->
    Nodes = participating_nodes(State),
    query_enabled_feature_flags_on_nodes(Nodes).

query_enabled_feature_flags_on_nodes(Nodes) ->
    query_feature_flags_on_nodes(Nodes, enabled).

query_feature_flags_on_nodes(Nodes, Status) ->
    [{Node,
      try
          gen_server:call({?MODULE, Node}, {query_feature_flags, Status})
      catch
          exit:{noproc, _} -> down
      end}
     || Node <- Nodes].

are_remote_feature_flags_supported(NodesAndFeatureFlags, State) ->
    Result = [case FeatureFlags of
                  down -> true; % TODO: How should we treat a remote node which is down?
                  _    -> are_feature_flags_supported(FeatureFlags, State)
              end
              || {_, FeatureFlags} <- NodesAndFeatureFlags],
    all_true(Result).

are_feature_flags_supported(FeatureFlags, State) ->
    Result = [is_feature_flag_supported(FeatureFlag, State) || FeatureFlag <- FeatureFlags],
    all_true(Result).

is_feature_flag_supported(FeatureFlag, #state{supported = Supported}) ->
    lists:member(FeatureFlag, Supported).

all_true(Result) ->
    lists:all(fun(I) -> I end, Result).

sumup_remote_feature_flags(NodesAndFeatureFlags) ->
    sumup_remote_feature_flags(NodesAndFeatureFlags, []).

sumup_remote_feature_flags([{_, FeatureFlags} | Rest], Result)
  when is_list(FeatureFlags) ->
    Result1 = lists:merge(Result, FeatureFlags),
    sumup_remote_feature_flags(Rest, Result1);
sumup_remote_feature_flags([{_, down} | Rest], Result) ->
    % TODO: What to do when a remote node doesn't respond?
    sumup_remote_feature_flags(Rest, Result);
sumup_remote_feature_flags([], Result) ->
    Result.

participating_nodes(_State) ->
    nodes().
