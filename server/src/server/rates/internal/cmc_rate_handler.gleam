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

/// Failures encountered while validating a rate request, requesting a CoinMarketCap
/// conversion, or interpreting its response.
pub type RateRequestError {
  /// A source or target currency ID is not positive. Carries the validation
  /// message; no provider request is made.
  ValidationError(String)

  /// CoinMarketCap rejected the source or target currency ID. Carries the
  /// corresponding ID from the rate request.
  CurrencyNotFound(Int)

  /// The HTTP request or JSON decoding failed. Carries the underlying CMC client
  /// error, including decoding failures for invalid provider timestamps.
  RequestFailed(CmcRequestError)

  /// A decoded response has an unhandled status, missing conversion data, or no
  /// quote for the requested target currency. Carries the decoded response.
  UnexpectedResponse(CmcResponse(CmcConversion))
}

/// Requests a CoinMarketCap conversion for one unit of the source currency into
/// the target currency using `request_conversion`.
///
/// Both currency IDs must be positive; validation happens before requesting.
/// A successful response uses the requested quote's `last_updated` timestamp in
/// Unix milliseconds. A null quote price is preserved as `rate: None`.
///
/// Missing conversion data or a missing target quote returns `UnexpectedResponse`.
/// Validation, request, decoding, and other response failures are represented by
/// `RateRequestError`.
pub fn get_rate(
  rate_request: RateRequest,
  request_conversion: RequestCmcConversion,
) -> Result(RateResponse, RateRequestError) {
  use from_id <- result.try(validate_currency_id(rate_request.from))
  use to_id <- result.try(validate_currency_id(rate_request.to))

  use cmc_response <- result.try(
    CmcConversionParameters(1.0, from_id, to_id)
    |> request_conversion
    |> result.map_error(RequestFailed),
  )

  cmc_response
  |> map_cmc_response(rate_request)
}

fn validate_currency_id(i: Int) -> Result(Int, RateRequestError) {
  case i > 0 {
    True -> Ok(i)
    False -> Error(ValidationError("Invalid currency id: " <> int.to_string(i)))
  }
}

fn map_cmc_response(
  cmc_response: CmcResponse(CmcConversion),
  rate_request: RateRequest,
) -> Result(RateResponse, RateRequestError) {
  let CmcResponse(CmcStatus(err_code, err_msg), data) = cmc_response

  case err_code, err_msg, data {
    400, Some("Invalid value for \"id\":" <> _), _ ->
      Error(CurrencyNotFound(rate_request.from))

    400, Some("Invalid value for \"convert_id\":" <> _), _ ->
      Error(CurrencyNotFound(rate_request.to))

    0, _, Some(conversion) -> {
      use quote_item <- result.try(
        conversion.quote
        |> dict.get(int.to_string(rate_request.to))
        |> result.replace_error(UnexpectedResponse(cmc_response)),
      )

      Ok(RateResponse(
        from: conversion.id,
        to: rate_request.to,
        rate: quote_item.price,
        source: CoinMarketCap,
        timestamp: quote_item.last_updated,
      ))
    }

    _, _, _ -> Error(UnexpectedResponse(cmc_response))
  }
}
