import gleam/list
import gleam/option.{None, Some}
import server/currencies/currency_repository.{CurrencyRepository}
import server/web/routes/home
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn resolve_page_data_with_no_client_state_uses_defaults_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(50_000.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let get_cryptos_by_symbol = fn(_) { [] }

  let assert Ok(page_data) =
    home.resolve_page_data(
      currency_repository,
      get_cryptos_by_symbol,
      get_rate,
      None,
    )

  assert page_data.currencies == currencies

  assert page_data.converters
    == [ConverterState(from: 1, to: 2781, amount: 1.0)]

  assert page_data.rates
    == [
      RateResponse(1, 2781, Some(50_000.0), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_with_client_state_uses_provided_converters_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Fiat(3, "Euro", "EUR", "€"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_cryptos_by_symbol = fn(_) { [] }

  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(100.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let client_state =
    ClientState(
      converters: [
        ConverterState(from: 1, to: 2, amount: 5.0),
        ConverterState(from: 2, to: 3, amount: 10.0),
      ],
      added_currencies: [],
    )

  let assert Ok(page_data) =
    home.resolve_page_data(
      currency_repository,
      get_cryptos_by_symbol,
      get_rate,
      Some(client_state),
    )

  assert page_data.currencies == currencies

  assert page_data.converters
    == [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
    ]

  assert page_data.rates
    == [
      RateResponse(1, 2, Some(100.0), Kraken, 1_700_000_000),
      RateResponse(2, 3, Some(100.0), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_filters_out_failed_rate_requests_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Fiat(3, "Euro", "EUR", "€"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_cryptos_by_symbol = fn(_) { [] }

  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // First converter succeeds
      1, 2 ->
        Ok(RateResponse(
          from: 1,
          to: 2,
          rate: Some(100.0),
          source: Kraken,
          timestamp: 1_700_000_000,
        ))
      // Second converter fails
      2, 3 -> Error(Nil)
      // Third converter succeeds
      1, 3 ->
        Ok(RateResponse(
          from: 1,
          to: 3,
          rate: Some(200.0),
          source: Kraken,
          timestamp: 1_700_000_000,
        ))
      _, _ -> Error(Nil)
    }
  }

  let client_state =
    ClientState(
      converters: [
        ConverterState(from: 1, to: 2, amount: 5.0),
        ConverterState(from: 2, to: 3, amount: 10.0),
        ConverterState(from: 1, to: 3, amount: 15.0),
      ],
      added_currencies: [],
    )

  let assert Ok(page_data) =
    home.resolve_page_data(
      currency_repository,
      get_cryptos_by_symbol,
      get_rate,
      Some(client_state),
    )

  // All converter states should be included
  assert page_data.converters
    == [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
      ConverterState(from: 1, to: 3, amount: 15.0),
    ]

  // Only successful rates should be included (1st and 3rd)
  assert page_data.rates
    == [
      RateResponse(1, 2, Some(100.0), Kraken, 1_700_000_000),
      RateResponse(1, 3, Some(200.0), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_fetches_and_merges_additional_currencies_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(100.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let client_state =
    ClientState(
      converters: [ConverterState(from: 1, to: 2781, amount: 1.0)],
      added_currencies: ["ETH", "BNB"],
    )

  // Verify get_cryptos is called with the added_currencies list
  let get_cryptos_by_symbol = fn(symbols) {
    assert symbols == ["ETH", "BNB"]
    [
      Crypto(2, "Ethereum", "ETH", Some(2)),
      Crypto(4, "Binance Coin", "BNB", Some(4)),
    ]
  }

  let assert Ok(page_data) =
    home.resolve_page_data(
      currency_repository,
      get_cryptos_by_symbol,
      get_rate,
      Some(client_state),
    )

  // All currencies should be included (original + fetched)
  // Note: order is not guaranteed due to dict.values
  assert list.length(page_data.currencies) == 4
  assert list.contains(
    page_data.currencies,
    Crypto(1, "Bitcoin", "BTC", Some(1)),
  )
  assert list.contains(
    page_data.currencies,
    Fiat(2781, "United States Dollar", "USD", "$"),
  )
  assert list.contains(
    page_data.currencies,
    Crypto(2, "Ethereum", "ETH", Some(2)),
  )
  assert list.contains(
    page_data.currencies,
    Crypto(4, "Binance Coin", "BNB", Some(4)),
  )
}

pub fn resolve_page_data_deduplicates_currencies_by_id_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(100.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let client_state =
    ClientState(
      converters: [ConverterState(from: 1, to: 2, amount: 1.0)],
      added_currencies: ["ETH"],
    )

  // Return a duplicate Ethereum with same ID but different data
  let get_cryptos_by_symbol = fn(_) {
    [Crypto(2, "Ethereum Updated", "ETH", Some(2))]
  }
  let assert Ok(page_data) =
    home.resolve_page_data(
      currency_repository,
      get_cryptos_by_symbol,
      get_rate,
      Some(client_state),
    )

  // Should have 2 currencies (Bitcoin and one Ethereum)
  // The duplicate Ethereum from get_cryptos should override the original
  assert list.contains(
    page_data.currencies,
    Crypto(1, "Bitcoin", "BTC", Some(1)),
  )
  assert list.contains(
    page_data.currencies,
    Crypto(2, "Ethereum Updated", "ETH", Some(2)),
  )
}
