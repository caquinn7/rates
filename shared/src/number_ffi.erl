-module(number_ffi).
-export([safe_multiply/2, safe_divide/2, safe_int_to_float/1, to_fixed/2]).

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

safe_int_to_float(Value) ->
  try
    {ok, erlang:float(Value)}
  catch
    error:badarg ->
      {error, nil}
  end.

to_fixed(Float, Digits) when Float >= 1.0e21, Digits >= 0 ->
  % Large fixed-decimal strings can exceed float_to_binary's output-size limit.
  % Floats at 1e21 and above cannot represent fractional parts, so format the
  % stored integer with integer_to_binary and add the requested decimal places
  % as zeros.
  Whole = integer_to_binary(trunc(Float)),
  case Digits of
    0 -> Whole;
    _ -> <<Whole/binary, ".", (binary:copy(<<"0">>, Digits))/binary>>
  end;
to_fixed(Float, Digits) when Digits >= 0 ->
  float_to_binary(Float, [{decimals, Digits}]).
