import birdie
import gleam/json
import shared/converter_input_state.{ConverterInputState}

pub fn encode_converter_input_state_to_json_test() {
  ConverterInputState(1, 2781, "1,000.0")
  |> converter_input_state.encode
  |> json.to_string
  |> birdie.snap("encode_converter_input_state_to_json_test")
}

pub fn decode_converter_input_state_test() {
  let json = "{\"from\":1,\"to\":2781,\"amount\":\"1,000.0\"}"

  assert json.parse(json, converter_input_state.decoder())
    == Ok(ConverterInputState(1, 2781, "1,000.0"))
}
