import gleam/erlang/process
import gleam/httpc
import gleam/option.{None, Some}
import server/currencies/cmc_currency_handler.{ClientError, MissingData}
import server/currencies/currency_fetcher.{
  CryptoRequest, EmptyListReceived, FiatRequest, HandlerError, RequestError,
  Timeout,
}
import server/integrations/coin_market_cap/client.{
  CmcResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{CmcFiatCurrency}

const good_cmc_status = CmcStatus(0, None)

pub fn get_currencies_crypto_missing_data_returns_handler_error_test() {
  let request_cryptos = fn() { Ok(CmcResponse(good_cmc_status, None)) }
  let request_fiats = fn() {
    Ok(CmcResponse(
      good_cmc_status,
      Some([CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]),
    ))
  }

  assert currency_fetcher.get_currencies(
      [],
      request_cryptos,
      request_fiats,
      1000,
    )
    == Error(RequestError(
      CryptoRequest,
      HandlerError(MissingData(good_cmc_status)),
    ))
}

pub fn get_currencies_fiat_missing_data_returns_handler_error_test() {
  let request_cryptos = fn() {
    Ok(CmcResponse(
      good_cmc_status,
      Some([CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]),
    ))
  }
  let request_fiats = fn() { Ok(CmcResponse(good_cmc_status, None)) }

  assert currency_fetcher.get_currencies(
      [],
      request_cryptos,
      request_fiats,
      1000,
    )
    == Error(RequestError(
      FiatRequest,
      HandlerError(MissingData(good_cmc_status)),
    ))
}

pub fn get_currencies_crypto_request_returns_handler_error_test() {
  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_cryptos = fn() { Error(expected_error) }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)

  assert Error(RequestError(
      CryptoRequest,
      HandlerError(ClientError(expected_error)),
    ))
    == result
}

pub fn get_currencies_crypto_request_returns_error_when_empty_list_received_test() {
  let request_cryptos = fn() {
    []
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)

  assert Error(RequestError(CryptoRequest, EmptyListReceived)) == result
}

pub fn get_currencies_fiat_request_returns_handler_error_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_fiats = fn() { Error(expected_error) }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)

  assert Error(RequestError(
      FiatRequest,
      HandlerError(ClientError(expected_error)),
    ))
    == result
}

pub fn get_currencies_fiat_request_returns_error_when_empty_list_received_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    []
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)

  assert Error(RequestError(FiatRequest, EmptyListReceived)) == result
}

pub fn get_currencies_returns_error_when_request_times_out() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let timeout = 25
  let request_fiats = fn() {
    process.sleep(timeout)

    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, timeout)

  assert Error(Timeout) == result
}

pub fn get_currencies_returns_both_crypto_and_fiat_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)

  let assert Ok([_, _]) = result
}
