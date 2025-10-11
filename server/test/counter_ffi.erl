-module(counter_ffi).
-export([get_or_zero/1, put_and_return_previous/2]).

get_or_zero(Key) ->
    case erlang:get(Key) of
        undefined -> 0;
        Value -> Value
    end.

put_and_return_previous(Key, Value) ->
    case erlang:put(Key, Value) of
        undefined -> 0;
        Previous -> Previous
    end.