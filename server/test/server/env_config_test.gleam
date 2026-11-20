import gleam/dict.{type Dict}
import server/env_config.{type EnvConfig, EnvConfig}

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
    |> load_with_vars

  assert EnvConfig("secret_key", "cmc_key", 50, ["USD", "EUR", "GBP"], "debug")
    == config
}

pub fn load_returns_error_when_secret_key_base_is_not_set_test() {
  assert Error("SECRET_KEY_BASE is required") == load_without("SECRET_KEY_BASE")
}

pub fn load_returns_error_when_cmc_api_key_is_not_set_test() {
  assert Error("COIN_MARKET_CAP_API_KEY is required")
    == load_without("COIN_MARKET_CAP_API_KEY")
}

pub fn load_checks_secret_key_base_first_test() {
  assert Error("SECRET_KEY_BASE is required") == load_with_vars(dict.new())
}

pub fn load_rejects_blank_secret_key_base_test() {
  assert Error("SECRET_KEY_BASE is required")
    == load_with_override("SECRET_KEY_BASE", "")
  assert Error("SECRET_KEY_BASE is required")
    == load_with_override("SECRET_KEY_BASE", " \t ")
}

pub fn load_rejects_blank_cmc_api_key_test() {
  assert Error("COIN_MARKET_CAP_API_KEY is required")
    == load_with_override("COIN_MARKET_CAP_API_KEY", "")
  assert Error("COIN_MARKET_CAP_API_KEY is required")
    == load_with_override("COIN_MARKET_CAP_API_KEY", " \t ")
}

pub fn load_preserves_credentials_verbatim_test() {
  let assert Ok(config) =
    all_vars
    |> dict.from_list
    |> dict.insert("SECRET_KEY_BASE", " secret_key ")
    |> dict.insert("COIN_MARKET_CAP_API_KEY", " cmc_key ")
    |> load_with_vars

  assert " secret_key " == config.secret_key_base
  assert " cmc_key " == config.cmc_api_key
}

pub fn load_returns_default_crypto_limit_when_not_set_test() {
  let assert Ok(config) = load_without("CRYPTO_LIMIT")

  assert 100 == config.crypto_limit
}

pub fn load_returns_default_crypto_limit_when_malformed_test() {
  let assert Ok(config) = load_with_override("CRYPTO_LIMIT", "invalid")

  assert 100 == config.crypto_limit
}

pub fn load_returns_default_supported_fiat_symbols_when_not_set_test() {
  let assert Ok(config) = load_without("SUPPORTED_FIAT_SYMBOLS")

  assert ["USD"] == config.supported_fiat_symbols
}

pub fn load_trims_fiat_symbols_and_discards_empty_tokens_test() {
  let assert Ok(config) =
    load_with_override("SUPPORTED_FIAT_SYMBOLS", "USD, , EUR,")

  assert ["USD", "EUR"] == config.supported_fiat_symbols
}

pub fn load_preserves_fiat_symbol_case_and_order_test() {
  let assert Ok(config) =
    load_with_override("SUPPORTED_FIAT_SYMBOLS", "eur, USD")

  assert ["eur", "USD"] == config.supported_fiat_symbols
}

pub fn load_rejects_fiat_lists_with_no_symbols_test() {
  let error = Error("SUPPORTED_FIAT_SYMBOLS must contain at least one symbol")

  assert error == load_with_override("SUPPORTED_FIAT_SYMBOLS", "")
  assert error == load_with_override("SUPPORTED_FIAT_SYMBOLS", " , , ")
}

pub fn load_returns_default_log_level_when_not_set_test() {
  let assert Ok(config) = load_without("LOG_LEVEL")

  assert "info" == config.log_level
}

fn load_without(key: String) -> Result(EnvConfig, String) {
  all_vars
  |> dict.from_list
  |> dict.delete(key)
  |> load_with_vars
}

fn load_with_override(key: String, value: String) -> Result(EnvConfig, String) {
  all_vars
  |> dict.from_list
  |> dict.insert(key, value)
  |> load_with_vars
}

fn load_with_vars(vars: Dict(String, String)) -> Result(EnvConfig, String) {
  env_config.load_with(dict.get(vars, _))
}
