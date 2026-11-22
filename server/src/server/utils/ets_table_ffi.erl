-module(ets_table_ffi).
-export([create/2]).

create(Name, Options) ->
    try ets:new(Name, Options) of
        Table -> {ok, Table}
    catch
        error:Reason:Stacktrace ->
            % The ETS frame includes the table options and OTP error details.
            EtsFrame = lists:sublist(Stacktrace, 1),
            Detail = erl_error:format_exception(error, Reason, EtsFrame),
            {error, unicode:characters_to_binary(Detail)}
    end.
