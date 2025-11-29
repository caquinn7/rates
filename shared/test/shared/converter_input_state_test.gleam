import birdie
import shared/converter_input_state.{ConverterInputState}

pub fn encode_handles_integer_amount_test() {
  assert converter_input_state.encode(ConverterInputState(1, 2781, "2"))
    == "1|2781|2"
}

pub fn encode_handles_amount_with_decimal_test() {
  assert converter_input_state.encode(ConverterInputState(1, 2781, "1.0"))
    == "1|2781|1.0"
}

pub fn encode_handles_amount_with_comma_test() {
  assert converter_input_state.encode(ConverterInputState(1, 2781, "1,000"))
    == "1|2781|1,000"
}

pub fn encode_handles_amount_with_decimal_and_comma_test() {
  assert converter_input_state.encode(ConverterInputState(1, 2781, "1,000.0"))
    == "1|2781|1,000.0"
}

pub fn encode_list_test() {
  converter_input_state.encode_list([
    ConverterInputState(1, 2781, "1.0"),
    ConverterInputState(2, 2781, "2.0"),
    ConverterInputState(3, 2781, "3"),
  ])
  |> birdie.snap("encode_list_test")
}

pub fn decode_handles_integer_amount_test() {
  assert converter_input_state.decode("1|2781|2")
    == Ok(ConverterInputState(1, 2781, "2"))
}

pub fn decode_handles_amount_with_decimal_test() {
  assert converter_input_state.decode("1|2781|2.0")
    == Ok(ConverterInputState(1, 2781, "2.0"))
}

pub fn decode_handles_amount_with_decimal_and_comma_test() {
  assert converter_input_state.decode("1|2781|1,000.0")
    == Ok(ConverterInputState(1, 2781, "1,000.0"))
}

pub fn decode_list_test() {
  assert converter_input_state.decode_list("1|2781|1.0;2|2781|2.0;3|2781|3")
    == Ok([
      ConverterInputState(1, 2781, "1.0"),
      ConverterInputState(2, 2781, "2.0"),
      ConverterInputState(3, 2781, "3"),
    ])
}

pub fn decode_returns_error_when_string_invalid_test() {
  // non-integer from_id
  assert converter_input_state.decode("x|2781|1.0") == Error(Nil)

  // non-integer to_id
  assert converter_input_state.decode("1|x|1.0") == Error(Nil)

  // missing field
  assert converter_input_state.decode("2|2781") == Error(Nil)
}

pub fn decode_list_returns_error_when_any_part_invalid_test() {
  // second portion missing amount
  assert converter_input_state.decode_list("1|2781|1.0;2|2781;3|2781|3")
    == Error(Nil)
}
