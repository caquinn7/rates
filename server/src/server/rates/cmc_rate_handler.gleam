import gleam/dict
import gleam/int
import gleam/option.{Some}
import gleam/result
import server/coin_market_cap/client.{
  type CmcConversion, type CmcConversionParameters, type CmcRequestError,
  type CmcResponse, CmcConversionParameters, CmcResponse, CmcStatus,
}
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
  |> map_cmc_response(rate_request, _)
}

fn map_cmc_response(
  rate_request: RateRequest,
  cmc_response: CmcResponse(CmcConversion),
) -> Result(RateResponse, RateRequestError) {
  let CmcResponse(CmcStatus(err_code, err_msg), data) = cmc_response

  case err_code, err_msg, data {
    400, Some("Invalid value for \"id\":" <> _), _ ->
      CurrencyNotFound(rate_request.from) |> Error

    400, Some("Invalid value for \"convert_id\":" <> _), _ ->
      CurrencyNotFound(rate_request.to) |> Error

    0, _, Some(conversion) ->
      conversion.quote
      |> dict.get(int.to_string(rate_request.to))
      |> result.map(fn(quote_item) {
        RateResponse(
          from: conversion.id,
          to: rate_request.to,
          rate: quote_item.price,
          source: CoinMarketCap,
        )
      })
      |> result.map_error(fn(_) { UnexpectedResponse(cmc_response) })

    _, _, _ -> {
      cmc_response
      |> UnexpectedResponse
      |> Error
    }
  }
}
