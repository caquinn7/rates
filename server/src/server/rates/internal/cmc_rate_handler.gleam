import gleam/dict
import gleam/int
import gleam/option.{Some}
import gleam/result
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, type CmcRequestError, type CmcResponse,
  CmcConversionParameters, CmcResponse, CmcStatus,
}
import server/integrations/coin_market_cap/cmc_conversion.{type CmcConversion}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{
  type RateResponse, CoinMarketCap, RateResponse,
}

pub type RequestCmcConversion =
  fn(CmcConversionParameters) ->
    Result(CmcResponse(CmcConversion), CmcRequestError)

pub type RateRequestError {
  ValidationError(String)
  CurrencyNotFound(Int)
  RequestFailed(CmcRequestError)
  UnexpectedResponse(CmcResponse(CmcConversion))
}

pub fn get_rate(
  rate_request: RateRequest,
  request_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Result(RateResponse, RateRequestError) {
  let validate_currency_id = fn(i) {
    case i > 0 {
      False ->
        Error(ValidationError("Invalid currency id: " <> int.to_string(i)))

      True -> Ok(i)
    }
  }

  use from_id <- result.try(validate_currency_id(rate_request.from))
  use to_id <- result.try(validate_currency_id(rate_request.to))

  use cmc_response <- result.try(
    CmcConversionParameters(1.0, from_id, to_id)
    |> request_conversion
    |> result.map_error(RequestFailed),
  )

  cmc_response
  |> map_cmc_response(rate_request, get_current_time_ms)
}

fn map_cmc_response(
  cmc_response: CmcResponse(CmcConversion),
  rate_request: RateRequest,
  get_current_time_ms: fn() -> Int,
) -> Result(RateResponse, RateRequestError) {
  let CmcResponse(CmcStatus(err_code, err_msg), data) = cmc_response

  case err_code, err_msg, data {
    400, Some("Invalid value for \"id\":" <> _), _ ->
      Error(CurrencyNotFound(rate_request.from))

    400, Some("Invalid value for \"convert_id\":" <> _), _ ->
      Error(CurrencyNotFound(rate_request.to))

    0, _, Some(conversion) -> {
      let rate =
        conversion.quote
        |> dict.get(int.to_string(rate_request.to))
        |> option.from_result
        |> option.then(fn(quote_item) { quote_item.price })

      Ok(RateResponse(
        from: conversion.id,
        to: rate_request.to,
        rate:,
        source: CoinMarketCap,
        timestamp: get_current_time_ms(),
      ))
    }

    _, _, _ -> Error(UnexpectedResponse(cmc_response))
  }
}
