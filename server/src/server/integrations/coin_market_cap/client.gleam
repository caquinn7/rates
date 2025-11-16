import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http/request.{type Request}
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

pub type CmcListResponse(a) {
  CmcListResponse(status: CmcStatus, data: Option(List(a)))
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
) -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError) {
  // only fails if url can't be parsed
  let assert Ok(req) = request.to(base_url <> "/v1/cryptocurrency/map")

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

  let req =
    req
    |> set_headers(api_key)
    |> request.set_query(params)

  use resp <- result.try(
    req
    |> httpc.send
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_list_response_decoder(cmc_crypto_currency.decoder()))
  |> result.map_error(JsonDecodeError)
}

pub fn get_fiat_currencies(
  api_key: String,
  limit: Option(Int),
) -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError) {
  let assert Ok(req) = request.to(base_url <> "/v1/fiat/map")
  let req =
    req
    |> set_headers(api_key)
    |> request.set_query([
      #("sort", "id"),
      #("limit", int.to_string(option.unwrap(limit, 100))),
    ])

  use resp <- result.try(
    req
    |> httpc.send
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_list_response_decoder(cmc_fiat_currency.decoder()))
  |> result.map_error(JsonDecodeError)
}

pub fn get_conversion(
  api_key: String,
  params: CmcConversionParameters,
) -> Result(CmcResponse(CmcConversion), CmcRequestError) {
  let CmcConversionParameters(amount, id, convert_id) = params

  let assert Ok(req) = request.to(base_url <> "/v2/tools/price-conversion")
  let req =
    req
    |> set_headers(api_key)
    |> request.set_query([
      #("amount", float.to_string(amount)),
      #("id", int.to_string(id)),
      #("convert_id", int.to_string(convert_id)),
    ])

  use resp <- result.try(
    req
    |> httpc.send
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_response_decoder(cmc_conversion.decoder()))
  |> result.map_error(JsonDecodeError)
}

fn set_headers(req: Request(a), api_key: String) -> Request(a) {
  req
  |> request.set_header("x-cmc_pro_api_key", api_key)
  |> request.set_header("accept", "application/json")
}

fn cmc_list_response_decoder(
  data_decoder: Decoder(a),
) -> Decoder(CmcListResponse(a)) {
  use status <- decode.field("status", status_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    decode.optional(decode.list(data_decoder)),
  )
  decode.success(CmcListResponse(status, data))
}

fn cmc_response_decoder(data_decoder: Decoder(a)) -> Decoder(CmcResponse(a)) {
  use status <- decode.field("status", status_decoder())
  use data <- decode.optional_field("data", None, decode.optional(data_decoder))
  decode.success(CmcResponse(status, data))
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
