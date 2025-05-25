import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option, None}
import gleam/result

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

pub type CmcCryptoCurrency {
  CmcCryptoCurrency(id: Int, rank: Option(Int), name: String, symbol: String)
}

pub type CmcFiatCurrency {
  CmcFiatCurrency(id: Int, name: String, sign: String, symbol: String)
}

pub type CmcConversionParameters {
  CmcConversionParameters(amount: Float, id: Int, convert_id: Int)
}

pub type CmcConversion {
  CmcConversion(
    id: Int,
    symbol: String,
    name: String,
    amount: Float,
    quote: Dict(String, QuoteItem),
  )
}

pub type QuoteItem {
  QuoteItem(price: Float)
}

const base_url = "https://pro-api.coinmarketcap.com"

pub fn get_crypto_currencies(
  api_key: String,
  limit: Int,
) -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError) {
  // only fails if url can't be parsed
  let assert Ok(req) = request.to(base_url <> "/v1/cryptocurrency/map")
  let req =
    req
    |> set_headers(api_key)
    |> request.set_query([
      #("sort", "cmc_rank"),
      #("limit", int.to_string(limit)),
      #("listing_status", "active"),
      #("aux", ""),
    ])

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_list_response_decoder(crypto_currency_decoder()))
  |> result.map_error(JsonDecodeError)
}

pub fn get_fiat_currencies(
  api_key: String,
  limit: Int,
) -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError) {
  let assert Ok(req) = request.to(base_url <> "/v1/fiat/map")
  let req =
    req
    |> set_headers(api_key)
    |> request.set_query([#("sort", "id"), #("limit", int.to_string(limit))])

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_list_response_decoder(fiat_currency_decoder()))
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
    httpc.send(req)
    |> result.map_error(HttpError),
  )

  resp.body
  |> json.parse(cmc_response_decoder(conversion_decoder()))
  |> result.map_error(JsonDecodeError)
}

fn set_headers(req: Request(a), api_key: String) -> Request(a) {
  req
  |> request.set_header("x-cmc_pro_api_key", api_key)
  |> request.set_header("accept", "application/json")
}

fn crypto_currency_decoder() -> Decoder(CmcCryptoCurrency) {
  use id <- decode.field("id", decode.int)
  use rank <- decode.optional_field("rank", None, decode.optional(decode.int))
  use name <- decode.field("name", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcCryptoCurrency(id, rank, name, symbol))
}

fn fiat_currency_decoder() -> Decoder(CmcFiatCurrency) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use sign <- decode.field("sign", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcFiatCurrency(id, name, sign, symbol))
}

fn conversion_decoder() -> Decoder(CmcConversion) {
  // {
  //     "id": 1,
  //     "symbol": "BTC",
  //     "name": "Bitcoin",
  //     "amount": 1.5,
  //     "last_updated": "2024-09-27T20:57:00.000Z",
  //     "quote": {
  //         "2010": {
  //             "price": 245304.45530431595,
  //             "last_updated": "2024-09-27T20:57:00.000Z"
  //         }
  //     }
  // }
  let int_or_float_decoder =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])

  let quote_decoder = {
    use price <- decode.field("price", int_or_float_decoder)
    decode.success(QuoteItem(price))
  }

  use id <- decode.field("id", decode.int)
  use symbol <- decode.field("symbol", decode.string)
  use name <- decode.field("name", decode.string)
  use amount <- decode.field("amount", int_or_float_decoder)
  use quote <- decode.field("quote", decode.dict(decode.string, quote_decoder))
  decode.success(CmcConversion(id, symbol, name, amount, quote))
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
