import gleam/dict
import gleam/httpc
import gleam/option.{None, Some}
import gleeunit/should
import server/coin_market_cap/client.{
  type CmcConversionParameters, CmcConversion, CmcResponse, CmcStatus, HttpError,
  QuoteItem,
}
import server/rates/cmc_rate_handler.{
  CurrencyNotFound, RequestFailed, UnexpectedResponse, ValidationError,
}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{RateResponse}

pub fn get_rate_invalid_base_id_test() {
  let request_conversion = fn(_) { panic }

  RateRequest(0, 1)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_invalid_quote_id_test() {
  let request_conversion = fn(_) { panic }

  RateRequest(1, 0)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_request_failed_test() {
  let request_conversion = fn(_) { Error(HttpError(httpc.InvalidUtf8Response)) }

  RateRequest(1, 2781)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(RequestFailed(HttpError(httpc.InvalidUtf8Response)))
}

pub fn get_rate_base_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(CmcStatus(400, Some("Invalid value for \"id\": ")), None))
  }

  RateRequest(1, 2781)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(CurrencyNotFound(1))
}

pub fn get_rate_quote_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(
      CmcStatus(400, Some("Invalid value for \"convert_id\": ")),
      None,
    ))
  }

  RateRequest(1, 2781)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(CurrencyNotFound(2781))
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

  RateRequest(1, 2781)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_ok
  |> should.equal(RateResponse(1, 2781, 100_000.0))
}

pub fn get_rate_unexpected_response_test() {
  let expected_response = CmcResponse(CmcStatus(0, None), None)
  let request_conversion = fn(_) { Ok(expected_response) }

  RateRequest(1, 2781)
  |> cmc_rate_handler.get_rate(request_conversion)
  |> should.be_error
  |> should.equal(UnexpectedResponse(expected_response))
}
