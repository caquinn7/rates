import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import server/context.{type Context}
import server/domain/currencies/cmc_currency_handler.{
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

pub fn get_currencies(
  ctx: Context,
  request_cryptos: RequestCmcCryptos,
  request_fiats: RequestCmcFiats,
  timeout: Int,
) -> CurrenciesResult {
  let try_fetch = fn(req_type) {
    let fetch =
      case req_type {
        CryptoRequest -> cmc_currency_handler.get_cryptos(request_cryptos)

        FiatRequest ->
          cmc_currency_handler.get_fiats(
            ctx.supported_fiat_symbols,
            request_fiats,
          )
      }
      |> result.map_error(HandlerError)
      |> result.map_error(RequestError(req_type, _))

    use currencies <- result.try(fetch)

    case currencies {
      [] ->
        EmptyListReceived
        |> RequestError(req_type, _)
        |> Error

      _ -> Ok(currencies)
    }
  }

  let start_time = time.monotonic_time_ms()
  let get_remaining_time = fn() {
    let now = time.monotonic_time_ms()
    let elapsed = now - start_time
    timeout - elapsed
  }

  let subject = process.new_subject()
  let spawn_fetch = fn(req_type) {
    process.spawn(fn() {
      req_type
      |> try_fetch
      |> process.send(subject, _)
    })
  }

  spawn_fetch(CryptoRequest)
  spawn_fetch(FiatRequest)
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
