import gleam/list
import gleam/option.{Some}
import gleam/result
import server/integrations/coin_market_cap/client.{
  type CmcRequestError, type CmcResponse, type CmcStatus, CmcApiError,
  CmcApiSuccess, CmcStatus,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{
  type CmcFiatCurrency,
}
import shared/currency.{type Currency, Crypto, Fiat}

pub type RequestCmcCryptos =
  fn() -> Result(CmcResponse(List(CmcCryptoCurrency)), CmcRequestError)

pub type RequestCmcFiats =
  fn() -> Result(CmcResponse(List(CmcFiatCurrency)), CmcRequestError)

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
/// CMC's invalid-symbol error yields `Ok([])`. Request and decoding failures
/// become `ClientError`. Other API errors become `ErrorStatusReceived`.
pub fn get_cryptos(
  request_crypto: RequestCmcCryptos,
) -> Result(List(Currency), FetchError) {
  use cmc_response <- result.try(
    request_crypto()
    |> result.map_error(ClientError),
  )

  use cryptos <- result.try(case cmc_response {
    CmcApiSuccess(_, data) -> Ok(data)
    CmcApiError(CmcStatus(_, Some("Invalid value for \"symbol\"" <> _)), _) ->
      Ok([])
    CmcApiError(status, _) -> Error(ErrorStatusReceived(status))
  })

  cryptos
  |> list.unique
  |> list.map(fn(crypto) {
    Crypto(crypto.id, crypto.name, crypto.symbol, crypto.rank)
  })
  |> Ok
}

/// Fetches fiat currencies using `request_fiat`, removes duplicate entries,
/// and maps those matching `supported_symbols` to `Fiat` currencies.
/// Symbol matching is case-sensitive. An empty list disables filtering.
///
/// Request and decoding failures become `ClientError`. API errors become
/// `ErrorStatusReceived`.
pub fn get_fiats(
  supported_symbols: List(String),
  request_fiat: RequestCmcFiats,
) -> Result(List(Currency), FetchError) {
  use cmc_response <- result.try(
    request_fiat()
    |> result.map_error(ClientError),
  )

  use fiats <- result.try(case cmc_response {
    CmcApiSuccess(_, data) -> Ok(data)
    CmcApiError(status, _) -> Error(ErrorStatusReceived(status))
  })

  fiats
  |> list.unique
  |> list.filter(fn(currency) {
    list.is_empty(supported_symbols)
    || list.contains(supported_symbols, currency.symbol)
  })
  |> list.map(fn(fiat) { Fiat(fiat.id, fiat.name, fiat.symbol, fiat.sign) })
  |> Ok
}
