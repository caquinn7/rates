import gleam/erlang/process
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import server/coin_market_cap/client.{
  CmcCryptoCurrency, CmcFiatCurrency, CmcListResponse, CmcStatus, HttpError,
}
import server/context.{Context}
import server/currencies/cmc_currency_handler.{
  Crypto, CurrenciesRequestError, Fiat, RequestFailed, TimedOut,
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

  Context("", 100, [])
  |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)
  |> should.be_error
  |> should.equal(CurrenciesRequestError(Crypto, RequestFailed(expected_error)))
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

  Context("", 100, [])
  |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)
  |> should.be_error
  |> should.equal(CurrenciesRequestError(Fiat, RequestFailed(expected_error)))
}

pub fn get_currencies_timeout_test() {
  let request_cryptos = fn(_) {
    process.sleep(5000)

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

  Context("", 100, [])
  |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 100)
  |> should.be_error
  |> should.equal(CurrenciesRequestError(Crypto, TimedOut))
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

  let currencies =
    Context("", 100, [])
    |> cmc_currency_handler.get_currencies(request_cryptos, request_fiats, 5000)
    |> should.be_ok

  currencies
  |> list.length
  |> should.equal(2)
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

  cmc_currency_handler.get_cryptos(100, request_cryptos)
  |> should.be_ok
  |> should.equal([currency.Crypto(1, "Bitcoin", "BTC", Some(1))])
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

  ["USD"]
  |> cmc_currency_handler.get_fiats(request_fiats)
  |> should.be_ok
  |> should.equal([currency.Fiat(2781, "United States Dollar", "USD", "$")])
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

  []
  |> cmc_currency_handler.get_fiats(request_fiats)
  |> should.be_ok
  |> should.equal([
    currency.Fiat(2781, "United States Dollar", "USD", "$"),
    currency.Fiat(9999, "Buck", "BCK", "B"),
  ])
}
