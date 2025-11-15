import gleam/dict
import gleam/httpc
import gleam/option.{None, Some}
import server/domain/rates/internal/cmc_rate_handler.{
  CurrencyNotFound, RequestFailed, UnexpectedResponse, ValidationError,
}
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, CmcResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, RateResponse}

pub fn get_rate_invalid_base_id_test() {
  let request_conversion = fn(_) { panic }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(0, 1)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Error(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_invalid_quote_id_test() {
  let request_conversion = fn(_) { panic }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 0)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Error(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_request_failed_test() {
  let request_conversion = fn(_) { Error(HttpError(httpc.InvalidUtf8Response)) }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Error(RequestFailed(HttpError(httpc.InvalidUtf8Response)))
}

pub fn get_rate_base_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(CmcStatus(400, Some("Invalid value for \"id\": ")), None))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Error(CurrencyNotFound(1))
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

  assert result == Error(CurrencyNotFound(2781))
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
        dict.from_list([#("2781", QuoteItem(Some(100_000.0)))]),
      )),
    ))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Ok(RateResponse(1, 2781, Some(100_000.0), CoinMarketCap, 1))
}

pub fn get_rate_returns_rate_when_rate_is_none_test() {
  let request_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        1.0,
        dict.from_list([#("2781", QuoteItem(None))]),
      )),
    ))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Ok(RateResponse(1, 2781, None, CoinMarketCap, 1))
}

pub fn get_rate_returns_none_as_rate_when_cmc_returns_empty_quote_test() {
  let request_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        1.0,
        dict.new(),
      )),
    ))
  }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Ok(RateResponse(1, 2781, None, CoinMarketCap, 1))
}

pub fn get_rate_unexpected_response_test() {
  let expected_response = CmcResponse(CmcStatus(0, None), None)
  let request_conversion = fn(_) { Ok(expected_response) }
  let get_current_time_ms = fn() { 1 }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion, get_current_time_ms)

  assert result == Error(UnexpectedResponse(expected_response))
}
