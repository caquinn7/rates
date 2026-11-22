import gleam/httpc
import gleam/option.{None, Some}
import server/currencies/cmc_currency_handler.{ClientError, ErrorStatusReceived}
import server/integrations/coin_market_cap/client.{
  CmcApiError, CmcApiSuccess, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{CmcFiatCurrency}
import shared/currency

const good_cmc_status = CmcStatus(0, None)

const bad_cmc_status = CmcStatus(400, Some("error"))

pub fn get_cryptos_test() {
  let request_cryptos = fn() {
    Ok(
      CmcApiSuccess(good_cmc_status, [
        CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC"),
      ]),
    )
  }

  let result = cmc_currency_handler.get_cryptos(request_cryptos)

  assert Ok([currency.Crypto(1, "Bitcoin", "BTC", Some(1))]) == result
}

pub fn get_cryptos_removes_duplicates_test() {
  let request_cryptos = fn() {
    Ok(
      CmcApiSuccess(good_cmc_status, [
        CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC"),
        CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC"),
      ]),
    )
  }

  let result = cmc_currency_handler.get_cryptos(request_cryptos)

  assert Ok([currency.Crypto(1, "Bitcoin", "BTC", Some(1))]) == result
}

pub fn get_cryptos_client_error_test() {
  let expected_client_err = HttpError(httpc.InvalidUtf8Response)
  let request_cryptos = fn() { Error(expected_client_err) }

  let result = cmc_currency_handler.get_cryptos(request_cryptos)

  assert Error(ClientError(expected_client_err)) == result
}

pub fn get_cryptos_api_error_with_data_returns_error_test() {
  let request_cryptos = fn() {
    Ok(CmcApiError(
      bad_cmc_status,
      Some([CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]),
    ))
  }

  assert cmc_currency_handler.get_cryptos(request_cryptos)
    == Error(ErrorStatusReceived(bad_cmc_status))
}

pub fn get_cryptos_empty_data_returns_empty_list_test() {
  let request_cryptos = fn() { Ok(CmcApiSuccess(good_cmc_status, [])) }

  assert cmc_currency_handler.get_cryptos(request_cryptos) == Ok([])
}

pub fn get_cryptos_error_status_test() {
  let request_cryptos = fn() { Ok(CmcApiError(bad_cmc_status, None)) }

  let result = cmc_currency_handler.get_cryptos(request_cryptos)

  assert Error(ErrorStatusReceived(bad_cmc_status)) == result
}

pub fn get_cryptos_returns_empty_list_when_symbol_not_found_test() {
  let request_cryptos = fn() {
    let msg = "Invalid value for \"symbol\": \"XYZ\""

    Ok(CmcApiError(CmcStatus(400, Some(msg)), None))
  }

  let result = cmc_currency_handler.get_cryptos(request_cryptos)

  assert Ok([]) == result
}

pub fn get_fiats_filters_out_unsupported_symbols_test() {
  let request_fiats = fn() {
    Ok(
      CmcApiSuccess(good_cmc_status, [
        CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
        CmcFiatCurrency(9999, "", "", "EUR"),
      ]),
    )
  }

  let result = cmc_currency_handler.get_fiats(["USD"], request_fiats)

  assert Ok([currency.Fiat(2781, "United States Dollar", "USD", "$")]) == result
}

pub fn get_fiats_removes_duplicates_test() {
  let request_fiats = fn() {
    Ok(
      CmcApiSuccess(good_cmc_status, [
        CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
        CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
      ]),
    )
  }

  let result = cmc_currency_handler.get_fiats(["USD"], request_fiats)

  assert Ok([currency.Fiat(2781, "United States Dollar", "USD", "$")]) == result
}

pub fn get_fiats_does_not_filter_when_supported_symbols_is_empty_test() {
  let request_fiats = fn() {
    Ok(
      CmcApiSuccess(good_cmc_status, [
        CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
        CmcFiatCurrency(9999, "Buck", "B", "BCK"),
      ]),
    )
  }

  let result = cmc_currency_handler.get_fiats([], request_fiats)

  assert result
    == Ok([
      currency.Fiat(2781, "United States Dollar", "USD", "$"),
      currency.Fiat(9999, "Buck", "BCK", "B"),
    ])
}

pub fn get_fiats_client_error_test() {
  let expected_client_err = HttpError(httpc.InvalidUtf8Response)
  let request_fiats = fn() { Error(expected_client_err) }

  let result = cmc_currency_handler.get_fiats([], request_fiats)

  assert Error(ClientError(expected_client_err)) == result
}

pub fn get_fiats_api_error_with_data_returns_error_test() {
  let request_fiats = fn() {
    Ok(CmcApiError(
      bad_cmc_status,
      Some([CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]),
    ))
  }

  assert cmc_currency_handler.get_fiats([], request_fiats)
    == Error(ErrorStatusReceived(bad_cmc_status))
}

pub fn get_fiats_empty_data_returns_empty_list_test() {
  let request_fiats = fn() { Ok(CmcApiSuccess(good_cmc_status, [])) }

  assert cmc_currency_handler.get_fiats([], request_fiats) == Ok([])
}

pub fn get_fiats_error_status_test() {
  let request_fiats = fn() { Ok(CmcApiError(bad_cmc_status, None)) }

  let result = cmc_currency_handler.get_fiats([], request_fiats)

  assert Error(ErrorStatusReceived(bad_cmc_status)) == result
}
