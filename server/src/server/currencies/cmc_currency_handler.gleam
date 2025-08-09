import gleam/list
import gleam/option.{Some}
import gleam/result
import server/coin_market_cap/client.{
  type CmcCryptoCurrency, type CmcFiatCurrency, type CmcListResponse,
  type CmcRequestError, type CmcStatus, CmcStatus,
}
import shared/currency.{type Currency, Crypto, Fiat}

pub type RequestCmcCryptos =
  fn() -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError)

pub type RequestCmcFiats =
  fn() -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError)

pub type FetchError {
  ClientError(CmcRequestError)
  ErrorStatusReceived(CmcStatus)
}

pub fn get_cryptos(
  request_crypto: RequestCmcCryptos,
) -> Result(List(Currency), FetchError) {
  use cmc_response <- result.try(
    request_crypto()
    |> result.map_error(ClientError),
  )

  use data <- result.try(case cmc_response.status.error_code == 0 {
    True -> Ok(cmc_response.data)

    False ->
      case cmc_response.status {
        CmcStatus(_, Some("Invalid value for \"symbol\"" <> _)) -> Ok(Some([]))

        _ -> Error(ErrorStatusReceived(cmc_response.status))
      }
  })

  let assert Some(cryptos) = data

  cryptos
  |> list.unique
  |> list.map(fn(crypto) {
    Crypto(crypto.id, crypto.name, crypto.symbol, crypto.rank)
  })
  |> Ok
}

pub fn get_fiats(
  supported_symbols: List(String),
  request_fiat: RequestCmcFiats,
) -> Result(List(Currency), FetchError) {
  use cmc_response <- result.try(
    request_fiat()
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
  |> list.map(fn(fiat) { Fiat(fiat.id, fiat.name, fiat.symbol, fiat.sign) })
  |> Ok
}
