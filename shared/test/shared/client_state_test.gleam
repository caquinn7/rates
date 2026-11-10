import gleam/list
import shared/client_state.{
  ClientState, ConverterState, InvalidAmount, InvalidCurrencyId, InvalidVersion,
  UnexpectedInput, VersionMissing,
}

// encode_converter_state

pub fn encode_converter_state_omits_amount_when_amount_is_one_test() {
  assert client_state.encode_converter_state(ConverterState(1, 2, 1.0)) == "1-2"
}

pub fn encode_converter_state_omits_amount_when_amount_is_less_than_zero_test() {
  assert client_state.encode_converter_state(ConverterState(1, 2, -1.0))
    == "1-2"
}

pub fn encode_converter_state_with_amount_test() {
  assert client_state.encode_converter_state(ConverterState(1, 2, 1.5))
    == "1-2-1.5"
}

pub fn encode_converter_state_outputs_integer_string_when_amount_precision_is_zero_test() {
  assert client_state.encode_converter_state(ConverterState(1, 2, 2.0))
    == "1-2-2"
}

// encode

pub fn encode_empty_state_test() {
  assert client_state.encode(ClientState([])) == "v1:"
}

pub fn encode_state_with_one_converter_test() {
  assert client_state.encode(ClientState([ConverterState(1, 2781, 0.5)]))
    == "v1:1-2781-0.5"
}

pub fn encode_state_with_multiple_converters_test() {
  assert client_state.encode(
      ClientState([ConverterState(1, 2781, 0.5), ConverterState(2, 2781, 1.5)]),
    )
    == "v1:1-2781-0.5;2-2781-1.5"
}

// decode_converter_state

pub fn decode_converter_state_returns_error_when_currency_id_is_not_an_int_test() {
  assert client_state.decode_converter_state("x-1") == Error(InvalidCurrencyId)
  assert client_state.decode_converter_state("1-x") == Error(InvalidCurrencyId)
}

pub fn decode_converter_state_returns_error_when_amount_is_not_a_number_test() {
  assert client_state.decode_converter_state("1-2-x") == Error(InvalidAmount)
}

pub fn decode_converter_state_returns_error_when_not_two_or_three_parts_test() {
  assert client_state.decode_converter_state("-") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("--") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("-1") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("1") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("1-") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("1--") == Error(UnexpectedInput)
  assert client_state.decode_converter_state("1-2-3-4")
    == Error(UnexpectedInput)
}

pub fn decode_converter_state_returns_ok_when_three_valid_parts_found_test() {
  assert client_state.decode_converter_state("1-2-3.0")
    == Ok(ConverterState(1, 2, 3.0))
}

pub fn decode_converter_state_returns_amount_of_one_when_amount_not_found_test() {
  assert client_state.decode_converter_state("1-2")
    == Ok(ConverterState(1, 2, 1.0))

  assert client_state.decode_converter_state("1-2-")
    == Ok(ConverterState(1, 2, 1.0))
}

pub fn decode_converter_state_preserves_negative_exponents_test() {
  list.each(
    ["1-2781-1.0e-8", "1-2781-1.0E-8", "1-2781-0.00000001"],
    fn(encoded) {
      assert client_state.decode_converter_state(encoded)
        == Ok(ConverterState(1, 2781, 0.00000001))
    },
  )
}

pub fn decode_converter_state_accepts_positive_exponents_test() {
  assert client_state.decode_converter_state("1-2781-1.0e+8")
    == Ok(ConverterState(1, 2781, 100_000_000.0))
}

pub fn decode_converter_state_rejects_malformed_separators_test() {
  list.each(
    [
      "-1-2781",
      "1--2781",
      "1-2781--3",
      "1-2781-3-",
      "1-2781-1.0e--8",
      "1-2781-1.0e-8-2",
    ],
    fn(encoded) {
      assert client_state.decode_converter_state(encoded)
        == Error(UnexpectedInput)
    },
  )
}

pub fn decode_converter_state_rejects_invalid_exponents_test() {
  list.each(
    ["1-2781-1.0e", "1-2781-1.0e-", "1-2781-1.0e+", "1-2781-1.0e-x"],
    fn(encoded) {
      assert client_state.decode_converter_state(encoded)
        == Error(InvalidAmount)
    },
  )
}

pub fn converter_state_round_trips_small_and_existing_amounts_test() {
  list.each([0.0, 1.0, 42.0, 1.5, 1.0e-10, 1.0e-8, 1.0e-7, 1.0e-6], fn(amount) {
    let state = ConverterState(1, 2781, amount)
    assert state
      |> client_state.encode_converter_state
      |> client_state.decode_converter_state
      == Ok(state)
  })
}

// decode

pub fn decode_returns_error_when_version_missing_test() {
  assert client_state.decode("") == Error(VersionMissing)
  assert client_state.decode(":") == Error(VersionMissing)
  assert client_state.decode("1-2781-1") == Error(VersionMissing)
  assert client_state.decode(":1-2781-1") == Error(VersionMissing)
}

pub fn decode_returns_error_when_version_invalid_test() {
  assert client_state.decode("x:1-2781-1") == Error(InvalidVersion("x"))
}

pub fn decode_empty_state_test() {
  assert client_state.decode("v1:") == Ok(ClientState([]))
}

pub fn decode_state_with_one_converter_test() {
  assert client_state.decode("v1:1-2781-0.5")
    == Ok(ClientState([ConverterState(1, 2781, 0.5)]))
}

pub fn decode_state_with_multiple_converters_test() {
  assert client_state.decode("v1:1-2781-0.5;2-2781-1")
    == Ok(
      ClientState([ConverterState(1, 2781, 0.5), ConverterState(2, 2781, 1.0)]),
    )
}

pub fn decode_state_with_empty_amount_test() {
  assert client_state.decode("v1:1-2781-;2-2781")
    == Ok(
      ClientState([ConverterState(1, 2781, 1.0), ConverterState(2, 2781, 1.0)]),
    )
}

pub fn client_state_round_trips_multiple_small_amounts_test() {
  let state =
    ClientState([
      ConverterState(1, 2781, 1.0e-10),
      ConverterState(1027, 2781, 1.0e-8),
      ConverterState(1, 1027, 1.0e-7),
      ConverterState(2781, 1, 1.0e-6),
    ])

  assert state |> client_state.encode |> client_state.decode == Ok(state)
}
