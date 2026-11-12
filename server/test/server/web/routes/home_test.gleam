import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import server/currencies/currency_repository.{
  type CurrencyRepository, CurrencyRepository,
}
import server/web/routes/home
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{type Currency, Crypto, Fiat}
import shared/numbers/positive_float
import shared/page_data
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}
import wisp

pub fn resolve_page_data_with_no_client_state_uses_defaults_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository = test_repository(currencies)

  let expected_rate = positive_float.from_float_unsafe(50_000.0)
  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(expected_rate),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let page_data = home.resolve_page_data(currency_repository, get_rate, None)

  assert page_data.currencies == currencies

  assert page_data.converters
    == [ConverterState(from: 1, to: 2781, amount: 1.0)]

  assert page_data.rates
    == [
      RateResponse(1, 2781, Some(expected_rate), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_with_client_state_uses_provided_converters_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Fiat(3, "Euro", "EUR", "€"),
  ]

  let currency_repository = test_repository(currencies)

  let expected_rate = positive_float.from_float_unsafe(100.0)
  let get_rate = fn(req: RateRequest) {
    Ok(RateResponse(
      from: req.from,
      to: req.to,
      rate: Some(expected_rate),
      source: Kraken,
      timestamp: 1_700_000_000,
    ))
  }

  let client_state =
    ClientState(converters: [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
    ])

  let page_data =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  assert page_data.currencies == currencies

  assert page_data.converters
    == [
      ConverterState(from: 1, to: 2, amount: 5.0),
      ConverterState(from: 2, to: 3, amount: 10.0),
    ]

  assert page_data.rates
    == [
      RateResponse(1, 2, Some(expected_rate), Kraken, 1_700_000_000),
      RateResponse(2, 3, Some(expected_rate), Kraken, 1_700_000_000),
    ]
}

pub fn resolve_page_data_keeps_converters_when_some_rate_requests_fail_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Fiat(3, "Euro", "EUR", "€"),
  ]

  let currency_repository = test_repository(currencies)

  let expected_rate_1 = positive_float.from_float_unsafe(100.0)
  let expected_rate_2 = positive_float.from_float_unsafe(200.0)

  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // First converter succeeds
      1, 2 ->
        Ok(RateResponse(
          from: 1,
          to: 2,
          rate: Some(expected_rate_1),
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
          rate: Some(expected_rate_2),
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

  let page_data =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

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
      RateResponse(1, 2, Some(expected_rate_1), Kraken, 1_700_000_000),
      RateResponse(1, 3, Some(expected_rate_2), Kraken, 1_700_000_000),
    ]
}

pub fn failed_rate_requests_preserve_saved_and_default_converters_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let repository = test_repository(currencies)

  let saved =
    ClientState([
      ConverterState(1027, 2781, 10.0),
      ConverterState(1, 2781, 0.00000001),
    ])
  let cases = [
    #(Some(saved), saved.converters),
    #(None, [ConverterState(1, 2781, 1.0)]),
    #(Some(ClientState([ConverterState(999, 888, 10.0)])), [
      ConverterState(1, 2781, 1.0),
    ]),
  ]

  list.each(cases, fn(test_case) {
    let #(state, expected_converters) = test_case
    let get_rate = fn(_) { Error(Nil) }
    let data = home.resolve_page_data(repository, get_rate, state)
    assert data.currencies == currencies
    assert data.converters == expected_converters
    assert data.rates == []

    let response = home.get(repository, get_rate, state)
    assert response.status == 200
    let assert wisp.Text(html) = response.body
    let assert Ok(#(_, seed_and_rest)) =
      string.split_once(html, "<script id=\"model\" type=\"application/json\">")
    let assert Ok(#(seed, _)) = string.split_once(seed_and_rest, "</script>")
    assert json.parse(seed, page_data.decoder()) == Ok(data)
  })
}

pub fn get_escapes_script_delimiters_without_changing_page_data_test() {
  let currencies = [
    Crypto(
      1,
      "Example </script><script>alert(\"seed\")</script> Coin",
      "BTC</ScRiPt>",
      Some(1),
    ),
    Fiat(2781, "<!--<script>US Dollar", "USD & \"", "<$ & € \\u003c >"),
  ]
  let rate =
    RateResponse(
      1,
      2781,
      Some(positive_float.from_float_unsafe(50_000.0)),
      Kraken,
      1_700_000_000,
    )
  let state = ClientState([ConverterState(1, 2781, 0.00000001)])
  let response =
    home.get(test_repository(currencies), fn(_) { Ok(rate) }, Some(state))

  assert response.status == 200
  let assert wisp.Text(html) = response.body
  let assert Ok(#(_, seed_and_rest)) =
    string.split_once(html, "<script id=\"model\" type=\"application/json\">")
  let assert Ok(#(seed, rest)) = string.split_once(seed_and_rest, "</script>")
  let assert Ok(data) = json.parse(seed, page_data.decoder())
  assert data.currencies == currencies
  assert data.rates == [rate]
  assert data.converters == state.converters
  assert !string.contains(seed, "<")
  assert string.starts_with(rest, "</head>")
}

fn test_repository(currencies: List(Currency)) -> CurrencyRepository {
  CurrencyRepository(
    insert: fn(_) { panic },
    get_by_id: fn(_) { panic },
    get_by_symbol: fn(_) { panic },
    get_all: fn() { currencies },
  )
}

pub fn resolve_page_data_does_not_fetch_rates_for_invalid_currency_ids_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2, "United States Dollar", "USD", "$"),
  ]

  let currency_repository = test_repository(currencies)

  let expected_rate_1 = positive_float.from_float_unsafe(100.0)

  // This function will panic if called with invalid currency IDs
  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // Valid: both currencies exist
      1, 2 ->
        Ok(RateResponse(
          from: 1,
          to: 2,
          rate: Some(expected_rate_1),
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

  let page_data =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  // Only converters with valid currency IDs should be included
  assert page_data.converters == [ConverterState(from: 1, to: 2, amount: 5.0)]

  // Only the valid rate should be fetched and included
  assert page_data.rates
    == [RateResponse(1, 2, Some(expected_rate_1), Kraken, 1_700_000_000)]
}

pub fn resolve_page_data_uses_default_converter_when_all_converters_invalid_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
    Crypto(5, "Ethereum", "ETH", Some(2)),
  ]

  let currency_repository = test_repository(currencies)

  let expected_rate = positive_float.from_float_unsafe(50_000.0)
  let get_rate = fn(req: RateRequest) {
    case req.from, req.to {
      // Default BTC -> USD should be called
      1, 2781 ->
        Ok(RateResponse(
          from: 1,
          to: 2781,
          rate: Some(expected_rate),
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

  let page_data =
    home.resolve_page_data(currency_repository, get_rate, Some(client_state))

  // Should fall back to default BTC -> USD converter
  assert page_data.converters
    == [ConverterState(from: 1, to: 2781, amount: 1.0)]

  assert page_data.rates
    == [RateResponse(1, 2781, Some(expected_rate), Kraken, 1_700_000_000)]
}
