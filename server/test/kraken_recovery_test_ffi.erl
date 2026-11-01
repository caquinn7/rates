-module(kraken_recovery_test_ffi).
-export([monitored_processes/1, linked_processes/1]).

monitored_processes(Pid) ->
    {monitors, Monitors} = process_info(Pid, monitors),
    [Target || {process, Target} <- Monitors, is_pid(Target)].

linked_processes(Pid) ->
    {links, Links} = process_info(Pid, links),
    [Target || Target <- Links, is_pid(Target)].
