import dot_env/env
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type EnvConfig {
  EnvConfig(
    secret_key_base: String,
    cmc_api_key: String,
    crypto_limit: Int,
    supported_fiat_symbols: List(String),
    log_level: String,
  )
}

pub fn load() -> Result(EnvConfig, String) {
  load_with(env.get_string)
}

pub fn load_with(
  get: fn(String) -> Result(String, error),
) -> Result(EnvConfig, String) {
  use secret_key_base <- result.try(required(get, "SECRET_KEY_BASE"))
  use cmc_api_key <- result.try(required(get, "COIN_MARKET_CAP_API_KEY"))

  let crypto_limit =
    get("CRYPTO_LIMIT")
    |> result.replace_error(Nil)
    |> result.try(int.parse)
    |> result.unwrap(100)

  use supported_fiat_symbols <- result.try(
    get("SUPPORTED_FIAT_SYMBOLS")
    |> result.unwrap("USD")
    |> parse_fiat_symbols,
  )

  let log_level = result.unwrap(get("LOG_LEVEL"), "info")

  Ok(EnvConfig(
    secret_key_base:,
    cmc_api_key:,
    crypto_limit:,
    supported_fiat_symbols:,
    log_level:,
  ))
}

fn required(
  get: fn(String) -> Result(String, error),
  key: String,
) -> Result(String, String) {
  let value = result.unwrap(get(key), "")
  case string.trim(value) {
    "" -> Error(key <> " is required")
    _ -> Ok(value)
  }
}

fn parse_fiat_symbols(value: String) -> Result(List(String), String) {
  let symbols =
    value
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(symbol) { !string.is_empty(symbol) })

  case symbols {
    [] -> Error("SUPPORTED_FIAT_SYMBOLS must contain at least one symbol")
    _ -> Ok(symbols)
  }
}
