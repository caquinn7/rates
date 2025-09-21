import gleam/dict
import gleam/httpc
import gleam/option.{None, Some}
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, CmcConversion, CmcResponse, CmcStatus, HttpError,
  QuoteItem,
}
import server/rates/cmc_rate_handler.{
  CurrencyNotFound, RequestFailed, UnexpectedResponse, ValidationError,
}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, RateResponse}

pub fn get_rate_invalid_base_id_test() {
  let request_conversion = fn(_) { panic }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(0, 1)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(ValidationError("Invalid currency id: 0")) == result
}

pub fn get_rate_invalid_quote_id_test() {
  let request_conversion = fn(_) { panic }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 0)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(ValidationError("Invalid currency id: 0")) == result
}

pub fn get_rate_request_failed_test() {
  let request_conversion = fn(_) { Error(HttpError(httpc.InvalidUtf8Response)) }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(RequestFailed(HttpError(httpc.InvalidUtf8Response))) == result
}

pub fn get_rate_base_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(CmcStatus(400, Some("Invalid value for \"id\": ")), None))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(CurrencyNotFound(1)) == result
}

pub fn get_rate_quote_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(
      CmcStatus(400, Some("Invalid value for \"convert_id\": ")),
      None,
    ))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(CurrencyNotFound(2781)) == result
}

pub fn get_rate_returns_rate_test() {
  let request_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        1.0,
        dict.from_list([#("2781", QuoteItem(100_000.0))]),
      )),
    ))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Ok(RateResponse(1, 2781, 100_000.0, CoinMarketCap, 1)) == result
}

pub fn get_rate_unexpected_response_test() {
  let expected_response = CmcResponse(CmcStatus(0, None), None)
  let request_conversion = fn(_) { Ok(expected_response) }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert Error(UnexpectedResponse(expected_response)) == result
}
