-module(process_test_ffi).
-export([monitored_processes/1, linked_processes/1, mailbox_size/1, owned_ets_tables/0]).

monitored_processes(Pid) ->
    {monitors, Monitors} = process_info(Pid, monitors),
    [Target || {process, Target} <- Monitors, is_pid(Target)].

linked_processes(Pid) ->
    {links, Links} = process_info(Pid, links),
    [Target || Target <- Links, is_pid(Target)].

mailbox_size(Pid) ->
    {message_queue_len, Size} = process_info(Pid, message_queue_len),
    Size.

owned_ets_tables() ->
    lists:sort([Table || Table <- ets:all(), ets:info(Table, owner) =:= self()]).
