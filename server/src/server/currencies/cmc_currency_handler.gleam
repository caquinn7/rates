import gleam/bool
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

pub type GetCurrencyError {
  ClientError(RequestType, CmcRequestError)
  ErrorStatusReceived(RequestType, CmcStatus)
  Timeout
}

pub type RequestType {
  CryptoRequest
  FiatRequest
}

type RequestCmcCryptos =
  fn(Int) -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError)

type RequestCmcFiats =
  fn(Int) -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError)

type CurrenciesResult =
  Result(List(Currency), GetCurrencyError)

pub fn get_currencies(
  ctx: Context,
  request_cryptos: RequestCmcCryptos,
  request_fiats: RequestCmcFiats,
  timeout: Int,
) -> CurrenciesResult {
  let subject = process.new_subject()

  process.start(
    fn() {
      get_cryptos(ctx.crypto_limit, request_cryptos)
      |> process.send(subject, _)
    },
    True,
  )

  process.start(
    fn() {
      get_fiats(ctx.supported_fiat_symbols, request_fiats)
      |> process.send(subject, _)
    },
    True,
  )

  receive_both(subject, None, None, timeout, current_time_ms(), current_time_ms)
}

pub fn get_cryptos(
  limit: Int,
  request_crypto: RequestCmcCryptos,
) -> CurrenciesResult {
  use cmc_response <- result.try(
    limit
    |> request_crypto
    |> result.map_error(ClientError(CryptoRequest, _)),
  )

  use data <- result.try(case cmc_response.status.error_code == 0 {
    True -> Ok(cmc_response.data)
    False -> Error(ErrorStatusReceived(CryptoRequest, cmc_response.status))
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
) -> CurrenciesResult {
  let select_supported_fiats = fn(currencies: List(CmcFiatCurrency)) {
    use <- bool.guard(list.is_empty(supported_symbols), currencies)

    currencies
    |> list.filter(fn(currency) {
      list.contains(supported_symbols, currency.symbol)
    })
  }

  use cmc_response <- result.try(
    100
    |> request_fiat
    |> result.map_error(ClientError(FiatRequest, _)),
  )

  use data <- result.try(case cmc_response.status.error_code == 0 {
    True -> Ok(cmc_response.data)
    False -> Error(ErrorStatusReceived(FiatRequest, cmc_response.status))
  })

  let assert Some(fiats) = data

  fiats
  |> list.unique
  |> select_supported_fiats
  |> list.map(fn(fiat) {
    currency.Fiat(fiat.id, fiat.name, fiat.symbol, fiat.sign)
  })
  |> Ok
}

fn receive_both(
  subject: Subject(CurrenciesResult),
  crypto_result: Option(CurrenciesResult),
  fiat_result: Option(CurrenciesResult),
  timeout: Int,
  start_time: Int,
  get_current_time: fn() -> Int,
) -> CurrenciesResult {
  let now = get_current_time()
  let elapsed = now - start_time
  let remaining = timeout - elapsed

  case crypto_result, fiat_result {
    Some(Ok(crypto)), Some(Ok(fiat)) -> Ok(list.append(crypto, fiat))

    Some(Error(err)), _ | _, Some(Error(err)) -> Error(err)

    _, _ ->
      case process.receive(subject, remaining) {
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
                timeout,
                start_time,
                get_current_time,
              )

            [Fiat(..), ..] ->
              receive_both(
                subject,
                crypto_result,
                Some(Ok(currencies)),
                timeout,
                start_time,
                get_current_time,
              )
          }
        }
      }
  }
}

fn current_time_ms() -> Int {
  monotonic_time(atom.create_from_string("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom) -> Int
