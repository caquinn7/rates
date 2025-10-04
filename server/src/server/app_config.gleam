pub type AppConfig {
  AppConfig(
    cmc_api_key: String,
    crypto_limit: Int,
    supported_fiat_symbols: List(String),
  )
}
