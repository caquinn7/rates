import gleam/erlang/process
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import server/app_config.{AppConfig}
import server/domain/currencies/cmc_currency_handler.{ClientError}
import server/domain/currencies/currencies_fetcher.{
  CryptoRequest, EmptyListReceived, FiatRequest, HandlerError, RequestError,
  Timeout,
}
import server/integrations/coin_market_cap/client.{
  CmcCryptoCurrency, CmcFiatCurrency, CmcListResponse, CmcStatus, HttpError,
}

const good_cmc_status = CmcStatus(0, None)

pub fn get_currencies_crypto_request_returns_handler_error_test() {
  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_cryptos = fn() { Error(expected_error) }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      100,
    )

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
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      100,
    )

  assert Error(RequestError(CryptoRequest, EmptyListReceived)) == result
}

pub fn get_currencies_fiat_request_returns_handler_error_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_fiats = fn() { Error(expected_error) }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      100,
    )

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
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    []
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      100,
    )

  assert Error(RequestError(FiatRequest, EmptyListReceived)) == result
}

pub fn get_currencies_returns_error_when_request_times_out() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let timeout = 25
  let request_fiats = fn() {
    process.sleep(timeout)

    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      timeout,
    )

  assert Error(Timeout) == result
}

pub fn get_currencies_returns_both_crypto_and_fiat_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_currencies(
      AppConfig("", 100, []),
      request_cryptos,
      request_fiats,
      100,
    )

  let assert Ok(currencies) = result
  assert list.length(currencies) == 2
}
