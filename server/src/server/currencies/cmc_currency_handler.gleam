import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import server/coin_market_cap/client.{
  type CmcCryptoCurrency, type CmcFiatCurrency, type CmcListResponse,
  type CmcRequestError, type CmcStatus,
}
import server/context.{type Context}
import shared/currency.{type Currency, Crypto, Fiat}

pub type CurrenciesResult =
  Result(List(Currency), CurrencyFetcherError)

pub type CurrencyFetcherError {
  RequestError(RequestType, RequestSpecificError)
  Timeout
}

pub type RequestSpecificError {
  ClientError(CmcRequestError)
  ErrorStatusReceived(CmcStatus)
  EmptyListReceived
}

pub type RequestType {
  CryptoRequest
  FiatRequest
}

type RequestCmcCryptos =
  fn(Int) -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError)

type RequestCmcFiats =
  fn(Int) -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError)

/// Fetches and combines crypto and fiat currencies from CMC.
/// 
/// Returns a combined list or detailed error.
pub fn get_currencies(
  ctx: Context,
  request_cryptos: RequestCmcCryptos,
  request_fiats: RequestCmcFiats,
  timeout: Int,
) -> CurrenciesResult {
  let get_currencies_by_type = fn(req_type) {
    let get_cryptos = fn() { get_cryptos(ctx.crypto_limit, request_cryptos) }

    let get_fiats = fn() {
      get_fiats(ctx.supported_fiat_symbols, request_fiats)
    }

    case req_type {
      CryptoRequest -> get_cryptos()
      FiatRequest -> get_fiats()
    }
    |> result.try(fn(currencies) {
      case currencies {
        [] -> Error(EmptyListReceived)
        _ -> Ok(currencies)
      }
    })
    |> result.map_error(RequestError(req_type, _))
  }

  let start_time = current_time_ms()
  let get_remaining_time = fn() {
    let now = current_time_ms()
    let elapsed = now - start_time
    timeout - elapsed
  }

  let subject = process.new_subject()

  process.spawn(fn() {
    get_currencies_by_type(CryptoRequest)
    |> process.send(subject, _)
  })

  process.spawn(fn() {
    get_currencies_by_type(FiatRequest)
    |> process.send(subject, _)
  })

  receive_both(subject, None, None, get_remaining_time)
}

fn receive_both(
  subject: Subject(CurrenciesResult),
  crypto_result: Option(CurrenciesResult),
  fiat_result: Option(CurrenciesResult),
  get_remaining_time: fn() -> Int,
) -> CurrenciesResult {
  case crypto_result, fiat_result {
    Some(Ok(crypto)), Some(Ok(fiat)) -> Ok(list.append(crypto, fiat))

    Some(Error(err)), _ | _, Some(Error(err)) -> Error(err)

    _, _ ->
      case process.receive(subject, get_remaining_time()) {
        Error(_) -> Error(Timeout)

        Ok(Error(err)) -> Error(err)

        Ok(Ok(currencies)) -> {
          case currencies {
            [] -> panic as "received empty currency list"

            [Crypto(..), ..] ->
              receive_both(
                subject,
                Some(Ok(currencies)),
                fiat_result,
                get_remaining_time,
              )

            [Fiat(..), ..] ->
              receive_both(
                subject,
                crypto_result,
                Some(Ok(currencies)),
                get_remaining_time,
              )
          }
        }
      }
  }
}

pub fn get_cryptos(
  limit: Int,
  request_crypto: RequestCmcCryptos,
) -> Result(List(Currency), RequestSpecificError) {
  use cmc_response <- result.try(
    limit
    |> request_crypto
    |> result.map_error(ClientError),
  )

  use data <- result.try(case cmc_response.status.error_code == 0 {
    True -> Ok(cmc_response.data)
    False -> Error(ErrorStatusReceived(cmc_response.status))
  })

  let assert Some(cryptos) = data

  cryptos
  |> list.unique
  |> list.map(fn(crypto) {
    currency.Crypto(crypto.id, crypto.name, crypto.symbol, crypto.rank)
  })
  |> Ok
}

pub fn get_fiats(
  supported_symbols: List(String),
  request_fiat: RequestCmcFiats,
) -> Result(List(Currency), RequestSpecificError) {
  use cmc_response <- result.try(
    100
    |> request_fiat
    |> result.map_error(ClientError),
  )

  use data <- result.try(case cmc_response.status.error_code == 0 {
    True -> Ok(cmc_response.data)
    False -> Error(ErrorStatusReceived(cmc_response.status))
  })

  let assert Some(fiats) = data

  fiats
  |> list.unique
  |> list.filter(fn(currency) {
    list.is_empty(supported_symbols)
    || list.contains(supported_symbols, currency.symbol)
  })
  |> list.map(fn(fiat) {
    currency.Fiat(fiat.id, fiat.name, fiat.symbol, fiat.sign)
  })
  |> Ok
}

fn current_time_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom) -> Int
