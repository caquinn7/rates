import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type ConverterInputState {
  ConverterInputState(from_id: Int, to_id: Int, amount: String)
}

pub fn encode_list(converter_input_states: List(ConverterInputState)) -> String {
  converter_input_states
  |> list.map(encode)
  |> string.join(";")
}

pub fn encode(converter_input_state: ConverterInputState) -> String {
  int.to_string(converter_input_state.from_id)
  <> "|"
  <> int.to_string(converter_input_state.to_id)
  <> "|"
  <> converter_input_state.amount
}

pub fn decode_list(s: String) -> Result(List(ConverterInputState), Nil) {
  s
  |> string.split(";")
  |> list.map(decode)
  |> result.all
}

pub fn decode(s: String) -> Result(ConverterInputState, Nil) {
  let parts = string.split(s, "|")

  case parts {
    [from_id, to_id, amount] -> {
      use from_id <- result.try(int.parse(from_id))
      use to_id <- result.try(int.parse(to_id))
      Ok(ConverterInputState(from_id, to_id, amount))
    }

    _ -> Error(Nil)
  }
}
