import gleam/option.{None, Some}
import server/domain/currencies/currency_interface.{CurrencyInterface}
import server/domain/rates/rate_error.{CurrencyNotFound}
import server/web/routes/home
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}

// resolve_page_data

pub fn resolve_page_data_with_no_client_state_uses_defaults_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_interface =
    CurrencyInterface(
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
    home.resolve_page_data(currency_interface, get_rate, None)

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

  let currency_interface =
    CurrencyInterface(
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
      converters: [
        ConverterState(from: 1, to: 2, amount: 5.0),
        ConverterState(from: 2, to: 3, amount: 10.0),
      ],
      added_currencies: [],
    )

  let assert Ok(page_data) =
    home.resolve_page_data(currency_interface, get_rate, Some(client_state))

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

  let currency_interface =
    CurrencyInterface(
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
      2, 3 -> Error(CurrencyNotFound(req, 2))
      // Third converter succeeds
      1, 3 ->
        Ok(RateResponse(
          from: 1,
          to: 3,
          rate: Some(200.0),
          source: Kraken,
          timestamp: 1_700_000_000,
        ))
      _, _ -> Error(CurrencyNotFound(req, 999))
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
    home.resolve_page_data(currency_interface, get_rate, Some(client_state))

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
