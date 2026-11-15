import exception
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

pub fn get_currencies_returns_error_when_request_times_out_test() {
  let started = process.new_subject()
  let results = process.new_subject()
  let request_cryptos = fn() {
    [CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let request_fiats = fn() {
    let release = process.new_subject()
    process.send(started, #(process.self(), release))
    let assert Ok(Nil) = process.receive(release, 1000)

    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")]
    |> Some
    |> CmcResponse(good_cmc_status, _)
    |> Ok
  }

  let _ =
    process.spawn(fn() {
      let result =
        currency_fetcher.get_currencies([], request_cryptos, request_fiats, 100)
      process.send(results, result)
    })

  let assert Ok(#(worker, release)) = process.receive(started, 1000)
  use <- exception.defer(fn() { process.send(release, Nil) })
  let monitor = process.monitor(worker)
  use <- exception.defer(fn() { process.demonitor_process(monitor) })

  assert process.receive(results, 1000) == Ok(Error(Timeout))
  assert process.is_alive(worker)

  process.send(release, Nil)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
}

pub fn get_currencies_returns_timeout_for_zero_budget_test() {
  assert_nonpositive_budget_times_out(0)
}

pub fn get_currencies_returns_timeout_for_negative_budget_test() {
  assert_nonpositive_budget_times_out(-1)
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

fn assert_nonpositive_budget_times_out(timeout: Int) {
  let request_cryptos = fn() {
    Ok(CmcResponse(
      good_cmc_status,
      Some([CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]),
    ))
  }
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
      timeout,
    )
    == Error(Timeout)
}
