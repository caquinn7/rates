import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import server/env_config.{type EnvInterface, EnvConfig, EnvInterface}

const all_vars = [
  #("SECRET_KEY_BASE", "secret_key"),
  #("COIN_MARKET_CAP_API_KEY", "cmc_key"),
  #("CRYPTO_LIMIT", "50"),
  #("SUPPORTED_FIAT_SYMBOLS", "USD,EUR,GBP"),
  #("LOG_LEVEL", "debug"),
]

pub fn load_returns_all_values_when_all_values_are_set_test() {
  let assert Ok(config) =
    all_vars
    |> dict.from_list
    |> mock_env_interface
    |> env_config.load_with_interface

  assert EnvConfig("secret_key", "cmc_key", 50, ["USD", "EUR", "GBP"], "debug")
    == config
}

pub fn load_returns_error_when_secret_key_base_is_not_set_test() {
  assert Error("SECRET_KEY_BASE is required")
    == env_config.load_with_interface(env_with_missing("SECRET_KEY_BASE"))
}

pub fn load_returns_error_when_cmc_api_key_is_not_set_test() {
  assert Error("COIN_MARKET_CAP_API_KEY is required")
    == env_config.load_with_interface(env_with_missing(
      "COIN_MARKET_CAP_API_KEY",
    ))
}

pub fn load_returns_default_crypto_limit_when_not_set_test() {
  let assert Ok(config) =
    env_config.load_with_interface(env_with_missing("CRYPTO_LIMIT"))
  assert 100 == config.crypto_limit
}

pub fn load_returns_default_supported_fiat_symbols_when_not_set_test() {
  let assert Ok(config) =
    env_config.load_with_interface(env_with_missing("SUPPORTED_FIAT_SYMBOLS"))

  assert ["USD"] == config.supported_fiat_symbols
}

pub fn load_returns_default_log_level_when_not_set_test() {
  let assert Ok(config) =
    env_config.load_with_interface(env_with_missing("LOG_LEVEL"))
  assert "info" == config.log_level
}

fn mock_env_interface(vars: Dict(String, String)) -> EnvInterface {
  EnvInterface(
    get_string: fn(key) {
      dict.get(vars, key)
      |> result.replace_error(Nil)
    },
    get_string_or: fn(key, default) {
      dict.get(vars, key)
      |> result.unwrap(default)
    },
    get_int_or: fn(key, default) {
      dict.get(vars, key)
      |> result.try(int.parse)
      |> result.unwrap(default)
    },
  )
}

fn env_with_missing(key: String) -> EnvInterface {
  let assert Ok(#(_, vars)) = list.key_pop(all_vars, key)

  vars
  |> dict.from_list
  |> mock_env_interface
}
