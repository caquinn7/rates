-module(number_ffi).
-export([safe_multiply/2, safe_divide/2, to_fixed/2]).

safe_multiply(A, B) ->
  try
    {ok, A * B}
  catch
    error:badarith ->
      {error, nil}
  end.

safe_divide(A, B) ->
  try
    {ok, A / B}
  catch
    error:badarith ->
      {error, nil}
  end.

to_fixed(Float, Digits) when Digits >= 0 ->
  float_to_binary(Float, [{decimals, Digits}]).
