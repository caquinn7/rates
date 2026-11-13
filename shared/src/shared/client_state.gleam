import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Converter configuration saved in the URL for restoring the page.
pub type ClientState {
  ClientState(
    /// Converters in display order. Duplicate currency pairs are allowed.
    converters: List(ConverterState),
  )
}

/// The saved configuration needed to recreate a converter.
pub type ConverterState {
  ConverterState(
    /// CoinMarketCap ID of the source (left-side) currency.
    from: Int,
    /// CoinMarketCap ID of the target (right-side) currency.
    to: Int,
    /// Left-side amount, expressed in the `from` currency.
    amount: Float,
  )
}

/// The initial state for fallback and newly added converters: 1 BTC to USD.
pub const default_converter: ConverterState =
  ConverterState(from: 1, to: 2781, amount: 1.0)

/// Encodes client state for the URL's `state` parameter, including the `v1:` prefix.
/// Converter entries are separated by `;`; an empty state encodes as `"v1:"`.
pub fn encode(state: ClientState) -> String {
  "v1:" <> encode_converter_states(state.converters)
}

/// Encodes converters as `;`-separated entries without a version prefix.
/// Preserves list order and duplicate pairs. An empty list encodes as `""`.
pub fn encode_converter_states(
  converter_states: List(ConverterState),
) -> String {
  converter_states
  |> list.map(encode_converter_state)
  |> string.join(";")
}

/// Encodes a converter as `from-to` or `from-to-amount`.
///
/// Omits amounts of `1.0` and negative amounts; omitted amounts decode as `1.0`.
/// Whole-number amounts use integer notation; others use `float.to_string`.
pub fn encode_converter_state(converter_state: ConverterState) -> String {
  let ConverterState(from, to, amount) = converter_state

  let amount_str = case amount {
    1.0 -> ""
    x if x <. 0.0 -> ""
    x -> {
      let truncated = float.truncate(x)
      case x == int.to_float(truncated) {
        True -> int.to_string(truncated)
        False -> float.to_string(x)
      }
    }
  }

  let converter_str = int.to_string(from) <> "-" <> int.to_string(to)
  case amount_str {
    "" -> converter_str
    _ -> converter_str <> "-" <> amount_str
  }
}

/// Failures when decoding the compact URL representation of client state.
pub type DecodeError {
  /// The input has no `:` separator, or the version prefix before it is empty.
  VersionMissing

  /// The version prefix is unsupported. Carries the unrecognized prefix.
  InvalidVersion(String)

  /// A source or target currency ID cannot be parsed as an integer.
  InvalidCurrencyId

  /// An explicit amount cannot be parsed as a floating-point number or integer.
  InvalidAmount

  /// A converter entry is missing a currency ID or has malformed separators.
  UnexpectedInput
}

/// Decodes a versioned URL state into converter configurations.
/// Requires the `v1:` prefix; `"v1:"` decodes to an empty converter list.
/// Fails if the version or any converter entry is invalid.
pub fn decode(encoded: String) -> Result(ClientState, DecodeError) {
  use content <- result.try(decode_version(encoded))
  use converters <- result.try(decode_converter_states(content))
  Ok(ClientState(converters:))
}

/// Validates the version prefix and returns the unparsed content after `v1:`.
///
/// Returns `VersionMissing` if the prefix is empty or no `:` separator exists,
/// and `InvalidVersion` for other prefixes.
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

/// Decodes a `;`-separated converter list without a version prefix.
/// An empty string produces `Ok([])`. Preserves order and duplicate pairs;
/// any invalid entry causes the whole list to fail decoding.
pub fn decode_converter_states(
  encoded: String,
) -> Result(List(ConverterState), DecodeError) {
  case string.split(encoded, ";") {
    [""] -> Ok([])
    parts ->
      parts
      |> list.map(decode_converter_state)
      |> result.all
  }
}

/// Decodes `from-to` or `from-to-amount` into a converter state.
///
/// Currency IDs must parse as integers. An omitted or empty amount defaults
/// to `1.0`; explicit amounts accept integer or float notation, including
/// scientific notation such as `"1.0e-8"`.
///
/// Returns `UnexpectedInput` for missing IDs or malformed separators,
/// `InvalidCurrencyId` for non-integer IDs, or `InvalidAmount` for amounts
/// that cannot be parsed.
pub fn decode_converter_state(
  encoded: String,
) -> Result(ConverterState, DecodeError) {
  // Split only the field separators: the amount may contain an exponent sign.
  use #(from, rest) <- result.try(
    encoded
    |> string.split_once("-")
    |> result.replace_error(UnexpectedInput),
  )
  let #(to, amount) =
    rest
    |> string.split_once("-")
    |> result.unwrap(#(rest, ""))

  use <- bool.guard(from == "" || to == "", Error(UnexpectedInput))
  use from <- result.try(parse_currency_id(from))
  use to <- result.try(parse_currency_id(to))
  use amount <- result.try(case amount {
    "" -> Ok(1.0)
    _ -> parse_amount(amount)
  })

  Ok(ConverterState(from, to, amount))
}

fn parse_amount(str: String) -> Result(Float, DecodeError) {
  // A remaining hyphen must be an exponent sign, not another field separator.
  let valid_hyphen = case string.split_once(str, "-") {
    Ok(#(before, after)) ->
      string.ends_with(string.lowercase(before), "e")
      && !string.contains(after, "-")
    Error(_) -> True
  }
  use <- bool.guard(!valid_hyphen, Error(UnexpectedInput))

  str
  |> float.parse
  |> result.lazy_or(fn() {
    str
    |> int.parse
    |> result.map(int.to_float)
  })
  |> result.replace_error(InvalidAmount)
}

fn parse_currency_id(str: String) -> Result(Int, DecodeError) {
  str
  |> int.parse
  |> result.replace_error(InvalidCurrencyId)
}
