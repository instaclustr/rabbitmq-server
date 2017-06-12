%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is AWeber Communications.
%% Copyright (c) 2015-2016 AWeber Communications
%% Copyright (c) 2016-2017 Pivotal Software, Inc. All rights reserved.
%%

-module(rabbit_peer_discovery_etcd).
-behaviour(rabbit_peer_discovery_backend).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_peer_discovery_common/include/rabbit_peer_discovery.hrl").

-export([list_nodes/0, supports_registration/0, register/0, unregister/0,
         post_registration/0, lock/1, unlock/1]).

-export([start_node_key_updater/0, update_node_key/0]).

-export([lock_ttl_update_callback/1]).

-define(CONFIG_MODULE, rabbit_peer_discovery_config).
-define(UTIL_MODULE,   rabbit_peer_discovery_util).
-define(HTTPC_MODULE,  rabbit_peer_discovery_httpc).

-define(BACKEND_CONFIG_KEY, peer_discovery_etcd).


-define(CONFIG_MAPPING,
         #{
          etcd_scheme    => #peer_discovery_config_entry_meta{
                              type          = string,
                              env_variable  = "ETCD_SCHEME",
                              default_value = "http"
                            },
          etcd_host      => #peer_discovery_config_entry_meta{
                              type          = string,
                              env_variable  = "ETCD_HOST",
                              default_value = "localhost"
                            },
          etcd_port      => #peer_discovery_config_entry_meta{
                              type          = integer,
                              env_variable  = "ETCD_PORT",
                              default_value = 2379
                            },
          etcd_prefix    => #peer_discovery_config_entry_meta{
                              type          = string,
                              env_variable  = "ETCD_PREFIX",
                              default_value = "rabbitmq"
                            },
          etcd_node_ttl  => #peer_discovery_config_entry_meta{
                              type          = integer,
                              env_variable  = "ETCD_NODE_TTL",
                              default_value = 30
                            },
          cluster_name   => #peer_discovery_config_entry_meta{
                              type          = string,
                              env_variable  = "CLUSTER_NAME",
                              default_value = "default"
                            },
          lock_wait_time  => #peer_discovery_config_entry_meta{
                                type          = integer,
                                env_variable  = "LOCK_WAIT_TIME",
                                default_value = 300
                               }
         }).


%%
%% API
%%

-spec list_nodes() -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}} | {error, Reason :: string()}.

list_nodes() ->
    case application:get_env(rabbit, cluster_formation) of
      undefined         ->
        {ok, {[], disc}};
      {ok, ClusterFormation} ->
        case proplists:get_value(?BACKEND_CONFIG_KEY, ClusterFormation) of
            undefined ->
              rabbit_log:warning("Peer discovery backend is set to ~s "
                                 "but final config does not contain rabbit.cluster_formation.peer_discovery_etcd. "
                                 "Cannot discover any nodes because etcd cluster details are not configured!",
                                 [?MODULE]),
              {ok, {[], disc}};
            Proplist  ->
              M = maps:from_list(Proplist),
              case etcd_get(nodes_path(M), [{recursive, true}], M) of
                  {ok, Nodes}  ->
                      NodeList = extract_nodes(Nodes),
                      {ok, NodeList};
                  {error, "404"} ->
                      {ok, []};
                  Error        -> Error
              end
        end
    end.


-spec supports_registration() -> boolean().

supports_registration() ->
    true.


-spec register() -> ok | {error, Reason :: string()}.
register() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    case set_etcd_node_key(M) of
        {ok, _} ->
            rabbit_log:info("Registered node with etcd"),
            ok;
        {error, Error}   ->
            rabbit_log:error("Failed to register node with etcd: ~s", [Error]),
            {error, Error}
    end.


-spec unregister() -> ok | {error, Reason :: string()}.
unregister() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    rabbit_log:info("Unregistering node with etcd"),
    case etcd_delete(node_path(M), [{recursive, true}], M) of
        {ok, _} -> ok;
        Error   -> Error
    end.

-spec post_registration() -> ok | {error, Reason :: string()}.

post_registration() ->
    start_node_key_updater(),
    ok.

-spec lock(Node :: atom()) -> {ok, Data :: term()} | {error, Reason :: string()}.

lock(Node) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    Now = time_compat:erlang_system_time(seconds),
    EndTime = Now + get_config_key(lock_wait_time, M),
    lock(atom_to_list(Node) ++ " - " ++ generate_unique_string(), Now, EndTime).


-spec unlock(Data :: term()) -> ok.

unlock({UniqueId, TRef}) ->
    stop_lock_ttl_updater(TRef),
    case delete_etcd_lock_key(UniqueId) of
        {ok, _} ->
            ok;
        {error, _} = Err ->
            Err
    end.

%%
%% Implementation
%%

-spec get_config_key(Key :: atom(), Map :: #{atom() => peer_discovery_config_value()})
             -> peer_discovery_config_value().

get_config_key(Key, Map) ->
    ?CONFIG_MODULE:get(Key, ?CONFIG_MAPPING, Map).

%% @doc Update etcd, setting a key for this node with a TTL of etcd_node_ttl
%% @end
-spec set_etcd_node_key(Map :: #{atom() => peer_discovery_config_value()})
                       -> ok | {error, Reason :: string()}.
set_etcd_node_key(Map) ->
  Interval = get_config_key(etcd_node_ttl, Map),
  etcd_put(node_path(Map), [{ttl, Interval}], [{value, enabled}], Map).

%% @doc Part of etcd path that allows us to distinguish different
%% cluster using the same etcd server.
%% @end
-spec cluster_name_path_part(Map :: #{atom() => peer_discovery_config_value()}) -> string().
cluster_name_path_part(Map) ->
    case get_config_key(cluster_name, Map) of
        "undefined" -> "default";
        Value       -> Value
    end.

%% @doc Return a list of path segments that are the base path for all
%% etcd keys related to current cluster.
%% @end
-spec base_path(Map :: #{atom() => peer_discovery_config_value()}) -> [?HTTPC_MODULE:path_component()].
base_path(Map) ->
  [v2, keys, get_config_key(etcd_prefix, Map), cluster_name_path_part(Map)].

%% @doc Returns etcd path under which nodes should be registered.
%% @end
-spec nodes_path(Map :: #{atom() => peer_discovery_config_value()}) -> [?HTTPC_MODULE:path_component()].
nodes_path(Map) ->
    base_path(Map) ++ [nodes].

%% @doc Returns etcd path under which current node should be registered
%% @end
-spec node_path(Map :: #{atom() => peer_discovery_config_value()}) -> [?HTTPC_MODULE:path_component()].
node_path(Map) ->
  nodes_path(Map) ++ [atom_to_list(node())].

%% @doc Return the list of erlang nodes
%% @end
%%
-spec extract_nodes(list(), list()) -> [node()].
extract_nodes([], Nodes) -> Nodes;
extract_nodes([H|T], Nodes) ->
  M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
  extract_nodes(T, lists:append(Nodes, [get_node_from_key(maps:get(<<"key">>, H), M)])).

%% @doc Return the list of erlang nodes
%% @end
%%
-spec extract_nodes(list()) -> [node()].
extract_nodes([]) -> [];
extract_nodes(Nodes) ->
  Dir = maps:get(<<"node">>, Nodes),
  case maps:get(<<"nodes">>, Dir, undefined) of
    undefined -> [];
    Values    -> extract_nodes(Values, [])
  end.


%% @doc Given an etcd key, return the erlang node name
%% @end
%%
-spec get_node_from_key(binary(), Map :: #{atom() => peer_discovery_config_value()}) -> node().
get_node_from_key(<<"/", V/binary>>, Map) -> get_node_from_key(V, Map);
get_node_from_key(V, Map) ->
  %% nodes path is /v2/keys/<etcd-prefix>/<cluster-name>/nodes
  %% etcd returns node keys as /<etcd-prefix>/<cluster-name>/nodes/<nodename>
  %% We are mapping path components from "<etcd-prefix>" up to "nodes",
  %% and discarding the same number of characters from the key returned by etcd.
  Path = string:concat(?HTTPC_MODULE:build_path(lists:sublist(nodes_path(Map), 3, 3)), "/"),
  ?UTIL_MODULE:node_name(string:substr(binary_to_list(V), length(Path))).

%% @doc Generate random string. We are using it for compare-and-change
%% operations in etcd.
%% @end
%% -spec generate_unique_string() -> string().
%% generate_unique_string() ->
%%     [ $a - 1 + rand:uniform(26) || _ <- lists:seq(1, 32) ].

-spec etcd_delete(Path, Query, Map)
                 -> {ok, term()} | {error, string()} when
      Path :: [?HTTPC_MODULE:path_component()],
      Query :: [?HTTPC_MODULE:query_component()],
      Map :: #{atom() => peer_discovery_config_value()}.
etcd_delete(Path, Query, Map) ->
    ?UTIL_MODULE:stringify_error(
      ?HTTPC_MODULE:delete(get_config_key(etcd_scheme, Map),
                           get_config_key(etcd_host, Map),
                           get_config_key(etcd_port, Map),
                           Path, Query, "")).

-spec etcd_get(Path, Query, Map)
              -> {ok, term()} | {error, string()} when
      Path :: [?HTTPC_MODULE:path_component()],
      Query :: [?HTTPC_MODULE:query_component()],
      Map :: #{atom() => peer_discovery_config_value()}.
etcd_get(Path, Query, Map) ->
    ?UTIL_MODULE:stringify_error(
      ?HTTPC_MODULE:get(get_config_key(etcd_scheme, Map),
                        get_config_key(etcd_host, Map),
                        get_config_key(etcd_port, Map),
                        Path, Query)).

-spec etcd_put(Path, Query, Body, Map) -> {ok, term()} | {error, string()} when
      Path :: [?HTTPC_MODULE:path_component()],
      Query :: [?HTTPC_MODULE:query_component()],
      Body :: [?HTTPC_MODULE:query_component()],
      Map :: #{atom() => peer_discovery_config_value()}.
etcd_put(Path, Query, Body, Map) ->
    ?UTIL_MODULE:stringify_error(
      ?HTTPC_MODULE:put(get_config_key(etcd_scheme, Map),
                        get_config_key(etcd_host, Map),
                        get_config_key(etcd_port, Map),
                        Path, Query, ?HTTPC_MODULE:build_query(Body))).


start_node_key_updater() ->
  case rabbit_peer_discovery:backend() of
    ?MODULE ->
      M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
      case get_config_key(etcd_node_ttl, M) of
        undefined -> ok;
        %% in seconds
        Interval  ->
         %% We cannot use timer:apply_interval/4 here because this
          %% function is executed in a short live process and when it
          %% exits, the timer module will automatically cancel the
          %% timer.
          %%
          %% Instead we delegate to a locally registered gen_server,
          %% `rabbitmq_peer_discovery_etcd_health_check_helper`.
          %%
          %% The value is 1/2 of what's configured to avoid a race
          %% condition between check TTL expiration and in flight
          %% notifications
          rabbitmq_peer_discovery_etcd_health_check_helper:start_timer(Interval * 500),
          ok
      end;
    _ -> ok
  end.

-spec update_node_key() -> ok.
update_node_key() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    set_etcd_node_key(M).

%% @doc
%% Tries to acquire the lock. Will retry until the lock is finally
%% granted or time is up.
%% @end
-spec lock(string(), pos_integer(), pos_integer()) -> ok | {error, string()}.
lock(_, Now, EndTime) when EndTime < Now ->
    {error, "Acquiring the lock taking too long, bailing out"};
lock(UniqueId, _, EndTime) ->
    case try_insert_lock_key(UniqueId) of
        true ->
            TRef = start_lock_ttl_updater(UniqueId),
            {ok, {UniqueId, TRef}};
        false ->
            wait_for_lock_release(),
            lock(UniqueId, time_compat:erlang_system_time(seconds), EndTime);
        {error, Reason} ->
            {error, lists:flatten(io_lib:format("Error while acquiring the lock, reason: ~p", [Reason]))}
    end.

%% @doc Tries to acquire a lock in etcd. This can either succeed, fail
%% because somebody else is holding the lock, or completely file due
%% to some I/O error.
%% @end
-spec try_insert_lock_key(string()) -> boolean() | {error, term()}.
try_insert_lock_key(UniqueId) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    Ttl = get_config_key(etcd_node_ttl, M),
    case set_etcd_lock_key(UniqueId, Ttl) of
        {ok, _} ->
            true;
        %% Precondition failed
        {error, "412"} ->
            false;
        {error, _} = Err ->
            Err
    end.

%% @doc Orders etcd to create startup lock key if it doesn't exist already.
%% @end
-spec set_etcd_lock_key(string(), non_neg_integer()) -> {ok, term()} | {error, string()}.
set_etcd_lock_key(UniqueId, Ttl) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    etcd_put(startup_lock_path(),
             [{ttl, Ttl}, {'prevExist', "false"}],
             [{value, UniqueId}],
             M).

%% @doc Returns etcd path for startup lock
%% @end
-spec startup_lock_path() -> [rabbit_peer_discovery_httpc:path_component()].
startup_lock_path() ->
    base_path() ++ ["startup_lock"].

%% @doc Return a list of path segments that are the base path for all
%% etcd keys related to current cluster.
%% @end
-spec base_path() -> [rabbit_peer_discovery_httpc:path_component()].
base_path() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    [v2, keys, get_config_key(etcd_prefix, M), get_config_key(cluster_name, M)].

%% @doc Generate random string. We are using it for compare-and-change
%% operations in etcd.
%% @end
-spec generate_unique_string() -> string().
generate_unique_string() ->
    [ $a - 1 + rand_compat:uniform(26) || _ <- lists:seq(1, 32) ].

-spec start_lock_ttl_updater(string()) -> ok.
start_lock_ttl_updater(UniqueId) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    Interval = get_config_key(etcd_node_ttl, M),
    rabbit_log:debug("Starting startup lock refresher"),
    {ok, TRef} = timer:apply_interval(Interval * 500, ?MODULE,
                                      lock_ttl_update_callback, [UniqueId]),
    TRef.

-spec stop_lock_ttl_updater(string()) -> ok.
stop_lock_ttl_updater(TRef) ->
    timer:cancel(TRef),
    rabbit_log:debug("Stopped startup lock refresher"),
    ok.

-spec wait_for_lock_release() -> ok.
wait_for_lock_release() ->
    %% XXX Try to use etcd wait feature, but we somehow need to know
    %% the index from the last lock attempt operation.
    timer:sleep(1000).

%% @doc Delete startup lock in etcd, but only if we are the holder of that lock.
%% @end
-spec delete_etcd_lock_key(string()) -> {ok, term()} | {error, string()}.
delete_etcd_lock_key(UniqueId) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    etcd_delete(startup_lock_path(),
                [{'prevExist', "true"}, {'prevValue', UniqueId}],
                M).

-spec lock_ttl_update_callback(string()) -> string().
lock_ttl_update_callback(UniqueId) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    _ = refresh_etcd_lock_ttl(UniqueId, get_config_key(etcd_node_ttl, M)),
    UniqueId.

%% @doc Refresh startup lock TTL in etcd, but only if we are the holder of that lock.
%% @end
-spec refresh_etcd_lock_ttl(string(), non_neg_integer()) -> {ok, term()} | {error, string()}.
refresh_etcd_lock_ttl(UniqueId, Ttl) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    etcd_put(startup_lock_path(),
             [],
             [{ttl, Ttl}, {'prevExist', true}, {'prevValue', UniqueId}, {refresh, true}],
             M).
