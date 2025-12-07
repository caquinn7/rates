import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type ClientState {
  ClientState(
    converters: List(ConverterState),
    // symbols of currencies added after page load
    added_currencies: List(String),
  )
}

// least amount of info needed to recreate a Converter
pub type ConverterState {
  ConverterState(from: Int, to: Int, amount: Float)
}

pub fn encode(state: ClientState) -> String {
  let ClientState(converters, added_currencies) = state

  let converters_str = encode_converter_states(converters)
  case string.join(added_currencies, ",") {
    "" -> "v1:" <> converters_str
    s -> "v1:" <> converters_str <> "|" <> s
  }
}

pub fn encode_converter_states(converter_states: List(ConverterState)) -> String {
  converter_states
  |> list.map(encode_converter_state)
  |> string.join(";")
}

pub fn encode_converter_state(converter_state: ConverterState) -> String {
  let ConverterState(from, to, amount) = converter_state

  // Encode amount for URL, omitting it entirely when possible to minimize URL length:
  // - If amount is 1.0 (the default), omit it from the URL
  // - If amount is negative (invalid), omit it from the URL
  // - Otherwise, optimize the encoding: whole numbers (e.g., 100.0) are encoded
  //   as integers ("100") rather than floats ("100.0") to save space
  let amount_str = case amount {
    1.0 -> ""
    x if x <. 0.0 -> ""
    x -> {
      let truncated = float.truncate(x)
      case x == int.to_float(truncated) {
        False -> float.to_string(x)
        True -> int.to_string(truncated)
      }
    }
  }

  let converter_str = int.to_string(from) <> "-" <> int.to_string(to)
  case amount_str {
    "" -> converter_str
    _ -> converter_str <> "-" <> amount_str
  }
}

pub type DecodeError {
  VersionMissing
  InvalidVersion(String)
  InvalidCurrencyId
  InvalidAmount
  UnexpectedInput
}

pub fn decode(encoded: String) -> Result(ClientState, DecodeError) {
  use content <- result.try(decode_version(encoded))
  use #(converters_str, currencies_str) <- result.try(
    case string.split(content, "|") {
      [""] -> Ok(#("", ""))
      [converters] | [converters, ""] -> Ok(#(converters, ""))
      ["", currencies] -> Ok(#("", currencies))
      [converters, currencies] -> Ok(#(converters, currencies))
      _ -> Error(UnexpectedInput)
    },
  )

  use converters <- result.try(decode_converter_states(converters_str))
  let added_currencies = split_and_remove_empty_strings(currencies_str, ",")
  Ok(ClientState(converters:, added_currencies:))
}

pub fn decode_version(encoded: String) -> Result(String, DecodeError) {
  use #(prefix, content) <- result.try(
    encoded
    |> string.split_once(":")
    |> result.replace_error(VersionMissing),
  )

  case prefix {
    "" -> Error(VersionMissing)
    "v1" -> Ok(content)
    _ -> Error(InvalidVersion(prefix))
  }
}

pub fn decode_converter_states(
  encoded: String,
) -> Result(List(ConverterState), DecodeError) {
  case string.split(encoded, ";") {
    [""] -> Ok([])
    parts ->
      parts
      |> list.map(fn(part) { decode_converter_state(part) })
      |> result.all
  }
}

pub fn decode_converter_state(
  encoded: String,
) -> Result(ConverterState, DecodeError) {
  let parse_currency_id = fn(str) {
    str
    |> int.parse
    |> result.replace_error(InvalidCurrencyId)
  }

  let parse_amount = fn(str) {
    str
    |> float.parse
    |> result.lazy_or(fn() {
      str
      |> int.parse
      |> result.map(int.to_float)
    })
    |> result.replace_error(InvalidAmount)
  }

  case split_and_remove_empty_strings(encoded, "-") {
    [from, to] -> {
      use from <- result.try(parse_currency_id(from))
      use to <- result.try(parse_currency_id(to))
      Ok(ConverterState(from, to, 1.0))
    }

    [from, to, amount] -> {
      use from <- result.try(parse_currency_id(from))
      use to <- result.try(parse_currency_id(to))
      use amount <- result.try(parse_amount(amount))
      Ok(ConverterState(from, to, amount))
    }

    _ -> Error(UnexpectedInput)
  }
}

fn split_and_remove_empty_strings(
  str: String,
  on substring: String,
) -> List(String) {
  str
  |> string.split(substring)
  |> list.filter(fn(s) { !string.is_empty(s) })
}
