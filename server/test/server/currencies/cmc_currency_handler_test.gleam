import gleam/erlang/process
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import server/coin_market_cap/client.{
  CmcCryptoCurrency, CmcFiatCurrency, CmcListResponse, CmcStatus, HttpError,
}
import server/context.{Context}
import server/currencies/cmc_currency_handler.{
  ClientError, CryptoRequest, FiatRequest, Timeout,
}
import shared/currency

pub fn get_currencies_crypto_request_failed_test() {
  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_cryptos = fn(_) { Error(expected_error) }

  let request_fiats = fn(_) {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result =
    Context("", 100, [])
    |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)

  assert result == Error(ClientError(CryptoRequest, expected_error))
}

pub fn get_currencies_fiat_request_failed_test() {
  let request_cryptos = fn(_) {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let expected_error = HttpError(httpc.InvalidUtf8Response)
  let request_fiats = fn(_) { Error(expected_error) }

  let result =
    Context("", 100, [])
    |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)

  assert result == Error(ClientError(FiatRequest, expected_error))
}

pub fn get_currencies_timeout_test() {
  let request_cryptos = fn(_) {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let timeout = 25
  let blocker = process.new_subject()
  let request_fiats = fn(_) {
    let _ = process.receive(blocker, timeout)

    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result =
    Context("", 100, [])
    |> cmc_currency_handler.get_currencies(
      request_cryptos,
      request_fiats,
      timeout,
    )

  assert result == Error(Timeout)
}

pub fn get_currencies_test() {
  let request_cryptos = fn(_) {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let request_fiats = fn(_) {
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result =
    Context("", 100, [])
    |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)

  let assert Ok(currencies) = result
  assert list.length(currencies) == 2
}

pub fn get_cryptos_test() {
  let request_cryptos = fn(_) {
    [
      CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC"),
      CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC"),
    ]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result = cmc_currency_handler.get_cryptos(100, request_cryptos)

  assert result == Ok([currency.Crypto(1, "Bitcoin", "BTC", Some(1))])
}

pub fn get_fiats_test() {
  let request_fiats = fn(_) {
    [
      CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
      CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
      CmcFiatCurrency(9999, "", "", ""),
    ]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result = cmc_currency_handler.get_fiats(["USD"], request_fiats)

  assert result == Ok([currency.Fiat(2781, "United States Dollar", "USD", "$")])
}

pub fn get_fiats_does_not_filter_when_supported_symbols_is_empty_test() {
  let request_fiats = fn(_) {
    [
      CmcFiatCurrency(2781, "United States Dollar", "$", "USD"),
      CmcFiatCurrency(9999, "Buck", "B", "BCK"),
    ]
    |> Some
    |> CmcListResponse(CmcStatus(0, None), _)
    |> Ok
  }

  let result = cmc_currency_handler.get_fiats([], request_fiats)

  assert result
    == Ok([
      currency.Fiat(2781, "United States Dollar", "USD", "$"),
      currency.Fiat(9999, "Buck", "BCK", "B"),
    ])
}
