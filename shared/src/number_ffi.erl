-module(number_ffi).
-export([safe_multiply/2]).

safe_multiply(A, B) ->
  try
    {ok, A * B}
  catch
    error:badarith ->
      {error, nil}
  end.
