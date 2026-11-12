import gleam/dict
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, type CmcRequestError, type CmcResponse,
  CmcResponse, CmcStatus, HttpError, JsonDecodeError,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  type CmcConversion, CmcConversion, QuoteItem,
}
import server/rates/internal/cmc_rate_handler.{
  CurrencyNotFound, RequestFailed, UnexpectedResponse, ValidationError,
}
import shared/numbers/positive_float
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, RateResponse}

pub fn get_rate_invalid_base_id_test() {
  let request_conversion = fn(_) { panic }

  let result =
    RateRequest(0, 1)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_invalid_quote_id_test() {
  let request_conversion = fn(_) { panic }

  let result =
    RateRequest(1, 0)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(ValidationError("Invalid currency id: 0"))
}

pub fn get_rate_request_failed_test() {
  let request_conversion = fn(_) { Error(HttpError(httpc.InvalidUtf8Response)) }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(RequestFailed(HttpError(httpc.InvalidUtf8Response)))
}

pub fn get_rate_response_timeout_is_a_request_error_test() {
  let request_conversion = fn(_) { Error(HttpError(httpc.ResponseTimeout)) }
  assert cmc_rate_handler.get_rate(RateRequest(1, 2781), request_conversion)
    == Error(RequestFailed(HttpError(httpc.ResponseTimeout)))
}

pub fn get_rate_base_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(CmcStatus(400, Some("Invalid value for \"id\": ")), None))
  }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(CurrencyNotFound(1))
}

pub fn get_rate_quote_id_not_found_test() {
  let request_conversion = fn(_) {
    Ok(CmcResponse(
      CmcStatus(400, Some("Invalid value for \"convert_id\": ")),
      None,
    ))
  }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(CurrencyNotFound(2781))
}

pub fn get_rate_returns_rate_test() {
  let expected_rate = positive_float.from_float_unsafe(100_000.0)

  let request_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        positive_float.from_float_unsafe(1.0),
        dict.from_list([
          #("2781", QuoteItem(Some(expected_rate), 1_794_145_983_000)),
        ]),
      )),
    ))
  }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result
    == Ok(RateResponse(
      1,
      2781,
      Some(expected_rate),
      CoinMarketCap,
      1_794_145_983_000,
    ))
}

pub fn get_rate_returns_rate_when_rate_is_none_test() {
  let request_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        positive_float.from_float_unsafe(1.0),
        dict.from_list([#("2781", QuoteItem(None, 1_794_145_983_000))]),
      )),
    ))
  }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result
    == Ok(RateResponse(1, 2781, None, CoinMarketCap, 1_794_145_983_000))
}

pub fn get_rate_rejects_a_missing_requested_quote_test() {
  [dict.new(), dict.from_list([#("2", QuoteItem(None, 123))])]
  |> list.each(fn(quotes) {
    let expected_response =
      CmcResponse(
        CmcStatus(0, None),
        Some(CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          positive_float.from_float_unsafe(1.0),
          quotes,
        )),
      )
    let request_conversion = fn(_) { Ok(expected_response) }

    let result =
      RateRequest(1, 2781)
      |> cmc_rate_handler.get_rate(request_conversion)

    assert result == Error(UnexpectedResponse(expected_response))
  })
}

pub fn get_rate_uses_the_requested_quotes_provider_time_test() {
  let payload =
    "{\"data\":{\"id\":39064,\"symbol\":\"NIGHT\",\"name\":\"Midnight\",\"amount\":1,\"quote\":{\"2781\":{\"price\":0.03994248803552823,\"last_updated\":\"2026-11-08T13:53:03.000Z\"},\"2\":{\"price\":2.0,\"last_updated\":\"2026-11-08T13:50:00Z\"}},\"last_updated\":\"2026-11-08T13:54:18.221Z\"},\"status\":{\"timestamp\":\"2026-11-08T13:54:26.139Z\",\"error_code\":0,\"error_message\":null}}"
  let request_conversion = fn(_) { decode_conversion_response(payload) }

  let assert Ok(rate) =
    cmc_rate_handler.get_rate(RateRequest(39_064, 2781), request_conversion)
  assert rate
    == RateResponse(
      39_064,
      2781,
      Some(positive_float.from_float_unsafe(0.03994248803552823)),
      CoinMarketCap,
      1_794_145_983_000,
    )

  let assert Ok(other_rate) =
    cmc_rate_handler.get_rate(RateRequest(39_064, 2), request_conversion)
  assert other_rate.timestamp == 1_794_145_800_000
}

pub fn get_rate_propagates_invalid_quote_timestamp_decoding_errors_test() {
  let payload =
    "{\"data\":{\"id\":1,\"symbol\":\"BTC\",\"name\":\"Bitcoin\",\"amount\":1,\"quote\":{\"2781\":{\"price\":100,\"last_updated\":\"invalid\"}}}}"
  let request_conversion = fn(_) { decode_conversion_response(payload) }
  let assert Error(RequestFailed(JsonDecodeError(json.UnableToDecode([error, ..])))) =
    cmc_rate_handler.get_rate(RateRequest(1, 2781), request_conversion)
  assert error.path == ["data", "quote", "2781", "last_updated"]
}

fn decode_conversion_response(
  payload: String,
) -> Result(CmcResponse(CmcConversion), CmcRequestError) {
  payload
  |> json.parse(decode.at(["data"], cmc_conversion.decoder()))
  |> result.map(fn(conversion) {
    CmcResponse(CmcStatus(0, None), Some(conversion))
  })
  |> result.map_error(JsonDecodeError)
}

pub fn get_rate_unexpected_response_test() {
  let expected_response = CmcResponse(CmcStatus(0, None), None)
  let request_conversion = fn(_) { Ok(expected_response) }

  let result =
    RateRequest(1, 2781)
    |> cmc_rate_handler.get_rate(request_conversion)

  assert result == Error(UnexpectedResponse(expected_response))
}
