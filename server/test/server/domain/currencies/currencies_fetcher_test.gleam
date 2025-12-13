import gleam/erlang/process
import gleam/httpc
import gleam/option.{None, Some}
import server/app_config.{AppConfig}
import server/domain/currencies/cmc_currency_handler.{ClientError}
import server/domain/currencies/currencies_fetcher.{
  CryptoRequest, EmptyListReceived, FiatRequest, HandlerError, RequestError,
  Timeout,
}
import server/integrations/coin_market_cap/client.{
  CmcListResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{CmcFiatCurrency}

const good_cmc_status = CmcStatus(0, None)

// get_cryptos

pub fn get_cryptos_returns_handler_error_test() {
  let expected_client_error = HttpError(httpc.InvalidUtf8Response)
  let request_cryptos = fn() { Error(expected_client_error) }

  let result = currencies_fetcher.get_cryptos(request_cryptos, 100)

  assert result
    == Error(RequestError(
      CryptoRequest,
      HandlerError(ClientError(expected_client_error)),
    ))
}

pub fn get_cryptos_returns_error_when_empty_list_received_test() {
  let request_cryptos = fn() {
    []
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result = currencies_fetcher.get_cryptos(request_cryptos, 100)

  assert result == Error(RequestError(CryptoRequest, EmptyListReceived))
}

pub fn get_cryptos_returns_error_when_request_times_out_test() {
  let timeout = 25
  let request_cryptos = fn() {
    process.sleep(timeout)

    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result = currencies_fetcher.get_cryptos(request_cryptos, timeout)

  assert result == Error(Timeout)
}

pub fn get_cryptos_returns_cryptos_test() {
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result = currencies_fetcher.get_cryptos(request_cryptos, 100)

  let assert Ok([_]) = result
}

// get_fiats

pub fn get_fiats_returns_handler_error_test() {
  let expected_client_error = HttpError(httpc.InvalidUtf8Response)
  let request_fiats = fn() { Error(expected_client_error) }

  let result =
    currencies_fetcher.get_fiats(AppConfig("", 100, []), request_fiats, 100)

  assert result
    == Error(RequestError(
      FiatRequest,
      HandlerError(ClientError(expected_client_error)),
    ))
}

pub fn get_fiats_returns_error_when_empty_list_received_test() {
  let request_fiats = fn() {
    []
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_fiats(AppConfig("", 100, []), request_fiats, 100)

  assert result == Error(RequestError(FiatRequest, EmptyListReceived))
}

pub fn get_fiats_returns_error_when_request_times_out_test() {
  let timeout = 25
  let request_fiats = fn() {
    process.sleep(timeout)

    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_fiats(AppConfig("", 100, []), request_fiats, timeout)

  assert result == Error(Timeout)
}

pub fn get_fiats_returns_fiats_test() {
  let request_fiats = fn() {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(good_cmc_status, _)
    |> Ok
  }

  let result =
    currencies_fetcher.get_fiats(AppConfig("", 100, []), request_fiats, 100)

  let assert Ok([_]) = result
}

// get_currencies

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

  let assert Ok([_, _]) = result
}
