import dot_env/env
import gleam/result
import gleam/string

pub type EnvInterface {
  EnvInterface(
    get_string: fn(String) -> Result(String, Nil),
    get_string_or: fn(String, String) -> String,
    get_int_or: fn(String, Int) -> Int,
  )
}

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
  load_with_interface(EnvInterface(
    fn(key) { result.replace_error(env.get_string(key), Nil) },
    env.get_string_or,
    env.get_int_or,
  ))
}

pub fn load_with_interface(
  env_interface: EnvInterface,
) -> Result(EnvConfig, String) {
  use secret_key_base <- result.try(
    "SECRET_KEY_BASE"
    |> env_interface.get_string
    |> result.map_error(fn(_) { "SECRET_KEY_BASE is required" }),
  )

  use cmc_api_key <- result.try(
    "COIN_MARKET_CAP_API_KEY"
    |> env_interface.get_string
    |> result.map_error(fn(_) { "COIN_MARKET_CAP_API_KEY is required" }),
  )

  let crypto_limit = env_interface.get_int_or("CRYPTO_LIMIT", 100)

  let supported_fiat_symbols = case
    env_interface.get_string("SUPPORTED_FIAT_SYMBOLS")
  {
    Error(_) -> ["USD"]
    Ok(s) -> string.split(s, ",")
  }

  let log_level = env_interface.get_string_or("LOG_LEVEL", "info")

  Ok(EnvConfig(
    secret_key_base:,
    cmc_api_key:,
    crypto_limit:,
    supported_fiat_symbols:,
    log_level:,
  ))
}
