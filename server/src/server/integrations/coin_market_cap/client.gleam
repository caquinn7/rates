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

pub type CmcRequestError {
  HttpError(httpc.HttpError)
  JsonDecodeError(json.DecodeError)
}

pub type CmcResponse(a) {
  CmcResponse(status: CmcStatus, data: Option(a))
}

pub type CmcStatus {
  CmcStatus(error_code: Int, error_message: Option(String))
}

pub type CmcConversionParameters {
  CmcConversionParameters(amount: Float, id: Int, convert_id: Int)
}

const base_url = "https://pro-api.coinmarketcap.com"

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

pub fn get_conversion(
  api_key: String,
  params: CmcConversionParameters,
  timeout_ms: Int,
) -> Result(CmcResponse(CmcConversion), CmcRequestError) {
  let CmcConversionParameters(amount:, id:, convert_id:) = params

  get(
    api_key,
    "/v2/tools/price-conversion",
    [
      #("amount", float.to_string(amount)),
      #("id", int.to_string(id)),
      #("convert_id", int.to_string(convert_id)),
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
  use data <- decode.then(response_data_decoder(status, data_decoder))
  decode.success(CmcResponse(status, data))
}

fn response_data_decoder(
  status: CmcStatus,
  data_decoder: Decoder(a),
) -> Decoder(Option(a)) {
  case status.error_code {
    0 -> decode.at(["data"], decode.map(data_decoder, Some))
    _ -> {
      use data <- decode.optional_field(
        "data",
        None,
        decode.optional(data_decoder),
      )
      decode.success(data)
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
