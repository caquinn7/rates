import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import server/currencies/cmc_currency_handler.{
  type FetchError, type RequestCmcCryptos, type RequestCmcFiats,
}
import server/utils/time
import shared/currency.{type Currency, Crypto, Fiat}

pub type CurrenciesResult =
  Result(List(Currency), CurrencyFetcherError)

pub type CurrencyFetcherError {
  RequestError(RequestType, RequestTypeSpecificError)
  Timeout
}

pub type RequestTypeSpecificError {
  HandlerError(FetchError)
  EmptyListReceived
}

pub type RequestType {
  CryptoRequest
  FiatRequest
}

/// Fetches crypto and fiat currencies concurrently within `timeout` milliseconds.
/// Both requests share one monotonic deadline. Nonpositive budgets return
/// `Error(Timeout)` without starting either request.
pub fn get_currencies(
  supported_fiat_symbols: List(String),
  request_cryptos: RequestCmcCryptos,
  request_fiats: RequestCmcFiats,
  timeout: Int,
) -> CurrenciesResult {
  case timeout <= 0 {
    True -> Error(Timeout)
    False -> {
      let deadline_ms = time.monotonic_time_ms() + timeout
      let subject = process.new_subject()

      spawn_fetch(subject, CryptoRequest, fn() {
        cmc_currency_handler.get_cryptos(request_cryptos)
      })

      spawn_fetch(subject, FiatRequest, fn() {
        cmc_currency_handler.get_fiats(supported_fiat_symbols, request_fiats)
      })

      receive_both(subject, None, None, deadline_ms)
    }
  }
}

fn receive_both(
  subject: Subject(CurrenciesResult),
  crypto_result: Option(CurrenciesResult),
  fiat_result: Option(CurrenciesResult),
  deadline_ms: Int,
) -> CurrenciesResult {
  case crypto_result, fiat_result {
    Some(Ok(crypto)), Some(Ok(fiat)) -> Ok(list.append(crypto, fiat))

    Some(Error(err)), _ | _, Some(Error(err)) -> Error(err)

    _, _ -> {
      let remaining_ms = deadline_ms - time.monotonic_time_ms()
      case remaining_ms <= 0 {
        True -> Error(Timeout)
        False ->
          case process.receive(subject, remaining_ms) {
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
                    deadline_ms,
                  )

                [Fiat(..), ..] ->
                  receive_both(
                    subject,
                    crypto_result,
                    Some(Ok(currencies)),
                    deadline_ms,
                  )
              }
            }
          }
      }
    }
  }
}

fn spawn_fetch(
  subject: Subject(CurrenciesResult),
  req_type: RequestType,
  fetch_fn: fn() -> Result(List(Currency), FetchError),
) -> Nil {
  process.spawn(fn() {
    let result = try_fetch(req_type, fetch_fn)
    process.send(subject, result)
  })

  Nil
}

fn try_fetch(
  req_type: RequestType,
  fetch_fn: fn() -> Result(List(Currency), FetchError),
) -> CurrenciesResult {
  fetch_fn()
  |> result.map_error(HandlerError)
  |> result.map_error(RequestError(req_type, _))
  |> result.try(fn(currencies) {
    case currencies {
      [] -> Error(RequestError(req_type, EmptyListReceived))
      _ -> Ok(currencies)
    }
  })
}
