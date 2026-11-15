//// Loads crypto and fiat currency metadata concurrently for server startup.
//// Both requests must return nonempty lists to assemble the currency catalog.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import server/currencies/cmc_currency_handler.{
  type FetchError, type RequestCmcCryptos, type RequestCmcFiats,
}
import server/utils/time
import shared/currency.{type Currency}

pub type CurrenciesResult =
  Result(List(Currency), LoadError)

/// Failures encountered while loading the startup currency catalog.
pub type LoadError {
  /// A crypto or fiat fetch failed. Retains the underlying handler error.
  FetchFailed(RequestType, FetchError)

  /// A request produced no supported currencies.
  EmptyCatalog(RequestType)

  /// The shared deadline expired or the supplied budget was nonpositive.
  Timeout
}

pub type RequestType {
  CryptoRequest
  FiatRequest
}

/// Fetches crypto and fiat currencies concurrently within `timeout` milliseconds.
/// Both requests share one monotonic deadline. Nonpositive budgets return
/// `Error(Timeout)` without starting either request.
/// The returned currency ordering is unspecified.
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

      use first <- result.try(receive_fetch(subject, deadline_ms))
      use second <- result.try(receive_fetch(subject, deadline_ms))
      Ok(list.append(first, second))
    }
  }
}

fn receive_fetch(
  subject: Subject(CurrenciesResult),
  deadline_ms: Int,
) -> CurrenciesResult {
  let remaining_ms = deadline_ms - time.monotonic_time_ms()
  case remaining_ms <= 0 {
    True -> Error(Timeout)
    False ->
      process.receive(subject, remaining_ms)
      |> result.replace_error(Timeout)
      |> result.flatten
  }
}

fn spawn_fetch(
  subject: Subject(CurrenciesResult),
  req_type: RequestType,
  fetch: fn() -> Result(List(Currency), FetchError),
) -> Nil {
  process.spawn(fn() {
    let result = try_fetch(req_type, fetch)
    process.send(subject, result)
  })

  Nil
}

fn try_fetch(
  req_type: RequestType,
  fetch: fn() -> Result(List(Currency), FetchError),
) -> CurrenciesResult {
  use currencies <- result.try(
    fetch()
    |> result.map_error(FetchFailed(req_type, _)),
  )

  case currencies {
    [] -> Error(EmptyCatalog(req_type))
    _ -> Ok(currencies)
  }
}
