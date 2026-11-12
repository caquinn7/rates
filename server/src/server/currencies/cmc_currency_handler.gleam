import gleam/list
import gleam/option.{Some}
import gleam/result
import server/integrations/coin_market_cap/client.{
  type CmcListResponse, type CmcRequestError, type CmcStatus, CmcStatus,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{
  type CmcFiatCurrency,
}
import shared/currency.{type Currency, Crypto, Fiat}

pub type RequestCmcCryptos =
  fn() -> Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError)

pub type RequestCmcFiats =
  fn() -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError)

/// Failures returned when fetching and interpreting CMC currency listings.
pub type FetchError {
  /// The HTTP request or JSON decoding failed. Carries the underlying client error.
  ClientError(CmcRequestError)

  /// A decoded response reports a provider error. Carries its error code and
  /// optional message in the original CMC status.
  ErrorStatusReceived(CmcStatus)
}

/// Fetches cryptocurrencies using `request_crypto`, removes duplicate entries,
/// and maps them to `Crypto` currencies.
///
/// CMC's invalid-symbol error yields `Ok([])`. Request failures become
/// `ClientError`; other provider error statuses become `ErrorStatusReceived`.
/// Panics if a successful response contains no data list.
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
        // Return empty list to client for invalid symbols (RESTful design)
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

/// Fetches fiat currencies using `request_fiat`, removes duplicate entries,
/// and maps those matching `supported_symbols` to `Fiat` currencies.
/// Symbol matching is case-sensitive; an empty list disables filtering.
///
/// Request failures become `ClientError`; provider error statuses become
/// `ErrorStatusReceived`. Panics if a successful response contains no data list.
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
