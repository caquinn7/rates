import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/integrations/coin_market_cap/cmc_conversion.{type CmcConversion}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{
  type CmcFiatCurrency,
}

/// Failures while making a CoinMarketCap request or decoding its response.
pub type CmcRequestError {
  /// The HTTP request failed. Carries the underlying HTTP client error.
  HttpError(httpc.HttpError)

  /// The response body could not be parsed as JSON or decoded into the expected
  /// shape. Carries the underlying JSON decoding error.
  JsonDecodeError(json.DecodeError)
}

/// A decoded CoinMarketCap response envelope.
pub type CmcResponse(a) {
  /// A zero status code with the required decoded endpoint data.
  CmcApiSuccess(status: CmcStatus, data: a)

  /// A nonzero status code with any endpoint data included in the response.
  CmcApiError(
    status: CmcStatus,
    /// Decoded endpoint data, or `None` if omitted or null.
    error_data: Option(a),
  )
}

/// The outcome of a request as reported by CoinMarketCap.
pub type CmcStatus {
  CmcStatus(
    /// CoinMarketCap status code. `0` indicates success.
    error_code: Int,
    /// Error message from CoinMarketCap, or `None` if omitted or null.
    error_message: Option(String),
  )
}

/// Query parameters for a CoinMarketCap price conversion.
pub type CmcConversionParameters {
  CmcConversionParameters(
    /// Amount to convert, in units of the source currency.
    amount: Float,
    /// CoinMarketCap ID of the source currency.
    id: Int,
    /// CoinMarketCap ID of the target currency.
    convert_id: Int,
  )
}

const base_url = "https://pro-api.coinmarketcap.com"

/// Fetches the CoinMarketCap cryptocurrency map.
///
/// Sends `listing_status=active` and `sort=cmc_rank`. Uses 100 when `limit` is
/// `None`. Trims `symbol` and omits the filter for `None` or a blank string.
///
/// `timeout_ms` sets the HTTP timeout in milliseconds. Returns decoded API
/// errors as `Ok(CmcApiError(...))`. Returns `Error` if the HTTP request or JSON
/// decoding fails.
pub fn get_crypto_currencies(
  api_key: String,
  limit: Option(Int),
  symbol: Option(String),
  timeout_ms: Int,
) -> Result(CmcResponse(List(CmcCryptoCurrency)), CmcRequestError) {
  let params = [
    #("sort", "cmc_rank"),
    #("limit", int.to_string(option.unwrap(limit, 100))),
    #("listing_status", "active"),
    // empty string aux tells cmc to omit some properties
    #("aux", ""),
  ]

  let params = case option.map(symbol, string.trim) {
    Some("") | None -> params
    Some(s) -> [#("symbol", s), ..params]
  }

  get(
    api_key,
    "/v1/cryptocurrency/map",
    params,
    timeout_ms,
    decode.list(cmc_crypto_currency.decoder()),
  )
}

/// Fetches the CoinMarketCap fiat currency map in CoinMarketCap ID order.
///
/// Uses 100 when `limit` is `None`. `timeout_ms` sets the HTTP timeout in
/// milliseconds.
///
/// Returns decoded API errors as `Ok(CmcApiError(...))`. Returns `Error` if the
/// HTTP request or JSON decoding fails.
pub fn get_fiat_currencies(
  api_key: String,
  limit: Option(Int),
  timeout_ms: Int,
) -> Result(CmcResponse(List(CmcFiatCurrency)), CmcRequestError) {
  get(
    api_key,
    "/v1/fiat/map",
    [
      #("sort", "id"),
      #("limit", int.to_string(option.unwrap(limit, 100))),
    ],
    timeout_ms,
    decode.list(cmc_fiat_currency.decoder()),
  )
}

/// Requests a CoinMarketCap price conversion for the amount and currency IDs
/// in `params`. The quote expresses the converted amount in target currency units.
///
/// `timeout_ms` sets the HTTP timeout in milliseconds. Returns decoded API
/// errors as `Ok(CmcApiError(...))`. Returns `Error` if the HTTP request or JSON
/// decoding fails.
pub fn get_conversion(
  api_key: String,
  params: CmcConversionParameters,
  timeout_ms: Int,
) -> Result(CmcResponse(CmcConversion), CmcRequestError) {
  get(
    api_key,
    "/v2/tools/price-conversion",
    [
      #("amount", float.to_string(params.amount)),
      #("id", int.to_string(params.id)),
      #("convert_id", int.to_string(params.convert_id)),
    ],
    timeout_ms,
    cmc_conversion.decoder(),
  )
}

fn get(
  api_key: String,
  path: String,
  params: List(#(String, String)),
  timeout_ms: Int,
  data_decoder: Decoder(a),
) -> Result(CmcResponse(a), CmcRequestError) {
  // All paths are fixed by the endpoint functions above.
  let assert Ok(req) = request.to(base_url <> path)
  let req =
    req
    |> request.set_header("x-cmc_pro_api_key", api_key)
    |> request.set_header("accept", "application/json")
    |> request.set_query(params)

  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(timeout_ms)
    |> httpc.dispatch(req)
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_response_decoder(data_decoder))
  |> result.map_error(JsonDecodeError)
}

/// Decodes a response envelope, requiring data when CMC reports success.
@internal
pub fn cmc_response_decoder(
  data_decoder: Decoder(a),
) -> Decoder(CmcResponse(a)) {
  use status <- decode.field("status", status_decoder())
  case status.error_code {
    0 -> decode.at(["data"], decode.map(data_decoder, CmcApiSuccess(status, _)))
    _ -> {
      use error_data <- decode.optional_field(
        "data",
        None,
        decode.optional(data_decoder),
      )
      decode.success(CmcApiError(status, error_data))
    }
  }
}

fn status_decoder() -> Decoder(CmcStatus) {
  use error_code <- decode.field("error_code", decode.int)
  use error_message <- decode.optional_field(
    "error_message",
    None,
    decode.optional(decode.string),
  )
  decode.success(CmcStatus(error_code, error_message))
}
