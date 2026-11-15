-module(logger_test_ffi).
-export([with_capture/3, log/2, format_message/1]).

with_capture(Level, Emit, Run) ->
    OriginalConfig = logger:get_primary_config(),
    HandlerId = rates_logger_test_capture,
    try
        ok = logger:set_primary_config(level, Level),
        ok = logger:add_handler(HandlerId, ?MODULE,
                                #{level => all,
                                  config => #{owner => self(), emit => Emit}}),
        Run()
    after
        logger:remove_handler(HandlerId),
        logger:set_primary_config(OriginalConfig)
    end.

log(Event, #{config := #{owner := Owner, emit := Emit}}) ->
    % Ignore events from background processes left running by other tests.
    case self() =:= Owner of
        true -> Emit(Event);
        false -> ok
    end,
    ok.

format_message(Event) ->
    unicode:characters_to_binary(logger_formatter:format(Event, #{template => [msg]})).
