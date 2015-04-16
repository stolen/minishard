-module(minishard_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([join_cluster/2, get_pid/2, add_pinger/3, add_pinger/4, pingers/1]).
-export([init/1]).

sup_name(root) ->
    minishard;
sup_name({cluster, ClusterName, _}) ->
    list_to_atom("minishard_" ++ atom_to_list(ClusterName) ++ "_sup");
sup_name({pingers, ClusterName}) ->
    list_to_atom("minishard_" ++ atom_to_list(ClusterName) ++ "_pingers");
sup_name({pinger_guard, ClusterName, Node, _}) ->
    list_to_atom("minishard_" ++ atom_to_list(ClusterName) ++ "_pguard_" ++ atom_to_list(Node)).

% Helper: get pid of started infrastructure part
get_pid(undefined, _) ->
    throw(undefined_cluster);
get_pid(ClusterName, pingers) when is_atom(ClusterName) ->
    strict_whereis(sup_name({pingers, ClusterName}));
get_pid(ClusterName, watcher) when is_atom(ClusterName) ->
    strict_whereis(minishard_watcher:name(ClusterName));
get_pid(ClusterName, shard) when is_atom(ClusterName) ->
    strict_whereis(minishard_shard:name(ClusterName));
get_pid(ClusterName, PartName) when is_atom(ClusterName), is_atom(PartName) ->
    Sup = sup_name({cluster, ClusterName, undefined}),
    Children = supervisor:which_children(Sup),
    case lists:keyfind(PartName, 1, Children) of
        {PartName, Pid, _, _} -> Pid;
        false -> undefined
    end.

strict_whereis(ProcessName) when is_atom(ProcessName) ->
    Pid = whereis(ProcessName),
    Pid == undefined andalso error(no_cluster),
    Pid.

start_link(Arg) ->
    supervisor:start_link({local, sup_name(Arg)}, ?MODULE, Arg).

join_cluster(ClusterName, CallbackMod) when is_atom(ClusterName), is_atom(CallbackMod) ->
    ClusterSpec = {ClusterName,
                   {?MODULE, start_link, [{cluster, ClusterName, CallbackMod}]},
                   permanent, 10000, supervisor, []},
    supervisor:start_child(sup_name(root), ClusterSpec).


%% Insert a new pinger into the pingers sup
add_pinger(ClusterName, Node, Watcher) when is_atom(ClusterName), is_atom(Node), is_pid(Watcher) ->
    PingersSup = get_pid(ClusterName, pingers),
    add_pinger(PingersSup, ClusterName, Node, Watcher).

add_pinger(PingersSup, ClusterName, Node, Watcher) when is_pid(PingersSup), is_atom(Node), is_pid(Watcher) ->
    PingerSupSpec = {Node,
                     {?MODULE, start_link, [{pinger_guard, ClusterName, Node, Watcher}]},
                     permanent, 150, supervisor, []},
    case supervisor:start_child(PingersSup, PingerSupSpec) of
        {ok, Pid} ->
            {ok, Pid};
        {error,{already_started,Pid}} ->
            {ok, Pid};
        Error ->
            Error
    end.


pingers(ClusterName) when is_atom(ClusterName) ->
    pingers(get_pid(ClusterName, pingers));
pingers(PingersSup) when is_pid(PingersSup) ->
    erlang:is_process_alive(PingersSup) orelse throw(dead_cluster),
    Children = supervisor:which_children(PingersSup),
    ValidPingers = [{Node, extract_pinger(PingersSup, Node, GuardPid)} || {Node, GuardPid, _, _} <- Children],
    lists:filter(fun({_, Pid}) -> is_pid(Pid) end, ValidPingers).

extract_pinger(PingersSup, Node, GuardPid) ->
    case supervisor:which_children(GuardPid) of
        [{_, Pid, _, _}] ->
            Pid;
        _ ->
            supervisor:terminate_child(PingersSup, Node),
            supervisor:delete_child(PingersSup, Node),
            undefined
    end.

init(root) ->
    GFixerSpec = {global_fixer,
                  {minishard_global_fixer, start_link, []},
                  permanent, 1000, worker, [minishard_global_fixer]},

    {ok, {{one_for_one, 1, 5}, [GFixerSpec]}};

init({cluster, ClusterName, CallbackMod}) ->
    WatcherSpec = {watcher,
                   {minishard_watcher, start_link, [ClusterName, CallbackMod]},
                   permanent, 1000, worker, [minishard_watcher]},
    PingersSpec = {pingers,
                   {?MODULE, start_link, [{pingers, ClusterName}]},
                   permanent, 1000, supervisor, []},
    ShardSpec = {shard,
                 {minishard_shard, start_link, [ClusterName, CallbackMod]},
                   permanent, 1000, worker, [minishard_shard]},

    {ok, {{one_for_all, 5, 10}, [WatcherSpec, PingersSpec, ShardSpec]}};

init({pingers, _}) ->
    {ok, {{one_for_one, 5, 5}, []}};

init({pinger_guard, ClusterName, Node, Watcher}) ->
    PingerSpec = {Node,
                  {minishard_pinger, start_link, [ClusterName, Node, Watcher]},
                  permanent, 100, worker, [minishard_pinger]},
    {ok, {{one_for_all, 5, 1}, [PingerSpec]}}.
