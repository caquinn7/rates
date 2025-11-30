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

  let converters_str =
    converters
    |> list.map(encode_converter_state)
    |> string.join(";")

  case string.join(added_currencies, ",") {
    "" -> "v1:" <> converters_str
    s -> "v1:" <> converters_str <> "|" <> s
  }
}

pub fn encode_converter_state(converter_state: ConverterState) -> String {
  let ConverterState(from, to, amount) = converter_state

  let converter_str = int.to_string(from) <> "-" <> int.to_string(to)

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
  let validate_prefix = fn() {
    use #(prefix, content) <- result.try(
      encoded
      |> string.split_once(":")
      |> result.replace_error(VersionMissing),
    )

    case prefix {
      "" -> Error(VersionMissing)
      "v1" -> Ok(#(prefix, content))
      _ -> Error(InvalidVersion(prefix))
    }
  }

  use #(_prefix, content) <- result.try(validate_prefix())

  use #(converters_str, currencies_str) <- result.try(
    case string.split(content, "|") {
      [""] -> Ok(#("", ""))
      [converters] | [converters, ""] -> Ok(#(converters, ""))
      ["", currencies] -> Ok(#("", currencies))
      [converters, currencies] -> Ok(#(converters, currencies))
      _ -> Error(UnexpectedInput)
    },
  )

  use converters <- result.try(case string.split(converters_str, ";") {
    [""] -> Ok([])
    parts ->
      parts
      |> list.map(fn(part) { decode_converter_state(part) })
      |> result.all
  })

  let added_currencies = split_and_remove_empty_strings(currencies_str, ",")

  Ok(ClientState(converters:, added_currencies:))
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
