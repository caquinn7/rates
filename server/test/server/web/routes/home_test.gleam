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

  let assert Ok(page_data) =
    home.resolve_page_data(currency_repository, get_rate, None)

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
    ClientState(converters: [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
    ])

  let assert Ok(page_data) =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

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
    ClientState(converters: [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
      ConverterState(from: 1, to: 3, amount: 15.0),
    ])

  let assert Ok(page_data) =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  // All converter states should be included
  assert page_data.converters
    == [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 1, to: 3, amount: 15.0),
    ]

  // Only successful rates should be included (1st and 3rd)
  assert page_data.rates
    == [
      RateResponse(1, 2, Some(100.0), Kraken, 1_700_000_000),
      RateResponse(1, 3, Some(200.0), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_does_not_fetch_rates_for_invalid_currency_ids_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  // This function will panic if called with invalid currency IDs
  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // Valid: both currencies exist
      1, 2 ->
        Ok(RateResponse(
          from: 1,
          to: 2,
          rate: Some(100.0),
          source: Kraken,
          timestamp: 1_700_000_000,
        ))
      // Invalid combinations should never be called
      _, _ -> panic as "get_rate called with invalid currency IDs"
    }
  }

  let client_state =
    ClientState(converters: [
      // Valid: both currencies exist
      ConverterState(from: 1, to: 2, amount: 5.0),
      // Invalid: from currency doesn't exist
      ConverterState(from: 999, to: 2, amount: 10.0),
      // Invalid: to currency doesn't exist
      ConverterState(from: 1, to: 888, amount: 15.0),
      // Invalid: both currencies don't exist
      ConverterState(from: 777, to: 666, amount: 20.0),
    ])

  let assert Ok(page_data) =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  // Only converters with valid currency IDs should be included
  assert page_data.converters == [ConverterState(from: 1, to: 2, amount: 5.0)]

  // Only the valid rate should be fetched and included
  assert page_data.rates
    == [RateResponse(1, 2, Some(100.0), Kraken, 1_700_000_000)]
}

pub fn resolve_page_data_uses_default_converter_when_all_converters_invalid_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
    Crypto(5, "Ethereum", "ETH", Some(2)),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { currencies },
    )

  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // Default BTC -> USD should be called
      1, 2781 ->
        Ok(RateResponse(
          from: 1,
          to: 2781,
          rate: Some(50_000.0),
          source: Kraken,
          timestamp: 1_700_000_000,
        ))
      _, _ -> panic as "get_rate called with unexpected currency pair"
    }
  }

  // Provide converters with invalid currency IDs only
  let client_state =
    ClientState(converters: [
      ConverterState(from: 999, to: 888, amount: 10.0),
      ConverterState(from: 777, to: 666, amount: 20.0),
    ])

  let assert Ok(page_data) =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  // Should fall back to default BTC -> USD converter
  assert page_data.converters
    == [ConverterState(from: 1, to: 2781, amount: 1.0)]

  assert page_data.rates
    == [RateResponse(1, 2781, Some(50_000.0), Kraken, 1_700_000_000)]
}
