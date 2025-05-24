import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{Some}
import gleam/otp/task
import gleam/result
import server/coin_market_cap/client.{
  type CmcCryptoCurrency, type CmcFiatCurrency, type CmcListResponse,
  type CmcRequestError,
}
import server/context.{type Context}
import shared/currency.{type Currency}

pub type RequestCmcCryptos =
  fn(Int) -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError)

pub type RequestCmcFiats =
  fn(Int) -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError)

pub type CurrenciesRequestError {
  CurrenciesRequestError(RequestType, RequestError)
}

pub type RequestType {
  Crypto
  Fiat
}

pub type RequestError {
  RequestFailed(CmcRequestError)
  TimedOut
  TaskCrashed(Dynamic)
}

pub fn get_currencies(
  ctx: Context,
  request_cryptos: RequestCmcCryptos,
  request_fiats: RequestCmcFiats,
  timeout: Int,
) -> Result(List(Currency), CurrenciesRequestError) {
  let crypto_task =
    task.async(fn() { get_cryptos(ctx.crypto_limit, request_cryptos) })

  let fiat_task =
    task.async(fn() { get_fiats(ctx.supported_fiat_symbols, request_fiats) })

  let #(crypto_result, fiat_result) =
    task.try_await2(crypto_task, fiat_task, timeout)

  use cryptos_result <- result.try(map_await_error(Crypto, crypto_result))
  use cryptos <- result.try(cryptos_result)

  use fiats_result <- result.try(map_await_error(Fiat, fiat_result))
  use fiats <- result.try(fiats_result)

  cryptos
  |> list.append(fiats)
  |> Ok
}

pub fn get_cryptos(
  limit: Int,
  request_cryptos: RequestCmcCryptos,
) -> Result(List(Currency), CurrenciesRequestError) {
  limit
  |> request_cryptos
  |> result.map(fn(cmc_response) {
    case cmc_response.data {
      Some(currencies) -> list.unique(currencies)
      _ -> []
    }
  })
  |> result.map(fn(cmc_cryptos) {
    cmc_cryptos
    |> list.map(fn(crypto) {
      currency.Crypto(crypto.id, crypto.name, crypto.symbol, crypto.rank)
    })
  })
  |> result.map_error(wrap_cmc_error(_, Crypto))
}

pub fn get_fiats(
  supported_symbols: List(String),
  request_fiats: RequestCmcFiats,
) -> Result(List(Currency), CurrenciesRequestError) {
  let select_supported_fiats = fn(currencies: List(CmcFiatCurrency)) {
    use <- bool.guard(list.is_empty(supported_symbols), currencies)

    currencies
    |> list.filter(fn(currency) {
      list.contains(supported_symbols, currency.symbol)
    })
  }

  100
  |> request_fiats
  |> result.map(fn(cmc_response) {
    case cmc_response.data {
      Some(currencies) ->
        currencies
        |> list.unique
        |> select_supported_fiats

      _ -> []
    }
  })
  |> result.map(fn(cmc_fiats) {
    cmc_fiats
    |> list.map(fn(fiat) {
      currency.Fiat(fiat.id, fiat.name, fiat.symbol, fiat.sign)
    })
  })
  |> result.map_error(wrap_cmc_error(_, Fiat))
}

fn map_await_error(
  request_type: RequestType,
  result: Result(a, task.AwaitError),
) -> Result(a, CurrenciesRequestError) {
  result
  |> result.map_error(fn(err) {
    case err {
      task.Timeout -> CurrenciesRequestError(request_type, TimedOut)
      task.Exit(reason) ->
        CurrenciesRequestError(request_type, TaskCrashed(reason))
    }
  })
}

fn wrap_cmc_error(cmc_request_err, req_type) {
  cmc_request_err
  |> RequestFailed
  |> CurrenciesRequestError(req_type, _)
}
