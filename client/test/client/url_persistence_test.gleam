import client.{type Model, Model}
import client/side.{Left, Right}
import client/ui/button_dropdown.{Enter}
import client/ui/converter
import client/websocket/websocket.{type WebSocket, OnTextMessage}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import shared/client_state.{type ClientState, ClientState, ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/numbers/non_negative_float
import shared/numbers/positive_float
import shared/page_data.{PageData}
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}
import shared/subscriptions/subscription_id
import shared/websocket_response.{
  RateUnavailable, SubscriptionFailed, SubscriptionUpdate,
}

const bitcoin_id = 1

const ethereum_id = 1027

const usd_id = 2781

const converter_id = "converter-1"

pub fn small_amount_survives_url_and_page_data_restoration_test() {
  use <- with_browser
  let initial = model_with_left_amount()
  let assert [target] = initial.converters
  let initial =
    initial
    |> client.model_with_converter(converter.with_amount(
      target,
      Left,
      "0.00000001",
    ))
    |> snapshot

  let saved = saved_state()
  assert saved == ClientState([ConverterState(bitcoin_id, usd_id, 0.00000001)])

  let seed =
    PageData(currencies: initial.currencies, converters: saved.converters)
    |> page_data.encode
    |> json.to_string

  let assert Ok(page_data) = json.parse(seed, page_data.decoder())
  let restored = client.model_from_page_data(page_data)
  let assert [waiting] = restored.converters
  assert converter.get_parsed_amount(waiting, Left) == Some(amount(0.00000001))
  assert converter.get_parsed_amount(waiting, Right) == None
  let restored =
    receive_response(
      restored,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe(converter_id),
        rate_response(RateRequest(bitcoin_id, usd_id), Some(rate(2.0))),
      ),
    )
  let assert [restored_converter] = restored.converters
  assert converter.get_selected_currency_id(restored_converter, Left)
    == bitcoin_id
  assert converter.get_selected_currency_id(restored_converter, Right) == usd_id
  assert converter.get_parsed_amount(restored_converter, Left)
    == Some(amount(0.00000001))
  assert converter.get_parsed_amount(restored_converter, Right)
    == Some(amount(0.00000002))

  let _ = snapshot(restored)
  assert saved_state() == saved
}

pub fn right_amount_survives_currency_changes_and_url_restoration_test() {
  use <- with_browser
  let ethereum = Crypto(ethereum_id, "Ethereum", "ETH", Some(2))

  list.each([Left, Right], fn(selection_side) {
    let selections = [
      converter.UserSelectedCurrency(selection_side, ethereum),
      converter.UserPressedKeyInCurrencySelector(selection_side, Enter),
    ]
    let request = case selection_side {
      Left -> RateRequest(ethereum_id, usd_id)
      Right -> RateRequest(bitcoin_id, ethereum_id)
    }

    list.each(selections, fn(selection) {
      let initial = model_with_right_amount()
      let assert [target] = initial.converters
      let #(target, _) =
        converter.update(
          target,
          converter.UserFilteredCurrencies(selection_side, "ETH"),
        )
      let target =
        converter.with_focused_index(target, selection_side, fn() { Some(0) })
      let initial = client.model_with_converter(initial, target)
      let initial = snapshot(initial)
      let previous_url = encoded_state()
      let previous_writes = url_write_count()

      let pending =
        update(initial, client.FromConverter(converter_id, selection))
      assert encoded_state() == previous_url
      assert url_write_count() == previous_writes

      let response = rate_response(request, Some(rate(4.0)))
      let settled =
        receive_response(
          pending,
          SubscriptionUpdate(
            subscription_id.from_string_unsafe(converter_id),
            response,
          ),
        )
      assert url_write_count() == previous_writes + 1
      let saved = saved_state()
      assert saved
        == ClientState([ConverterState(request.from, request.to, 25.0)])

      let restored =
        client.model_from_page_data(PageData(
          currencies: settled.currencies,
          converters: saved.converters,
        ))
      let assert [waiting] = restored.converters
      assert converter.get_parsed_amount(waiting, Left) == Some(amount(25.0))
      assert converter.get_parsed_amount(waiting, Right) == None
      let restored =
        receive_response(
          restored,
          SubscriptionUpdate(
            subscription_id.from_string_unsafe(converter_id),
            response,
          ),
        )
      let assert [restored_converter] = restored.converters
      assert converter.get_parsed_amount(restored_converter, Left)
        == Some(amount(25.0))
      assert converter.get_parsed_amount(restored_converter, Right)
        == Some(amount(100.0))
    })
  })
}

pub fn unavailable_or_unmatched_rates_keep_the_last_valid_url_test() {
  use <- with_browser
  let initial = snapshot(model_with_right_amount())
  let previous_url = encoded_state()
  let previous_writes = url_write_count()
  let request = RateRequest(ethereum_id, usd_id)
  let id = subscription_id.from_string_unsafe(converter_id)
  let pending = select_ethereum(initial)
  let responses = [
    SubscriptionUpdate(
      id,
      rate_response(RateRequest(bitcoin_id, usd_id), Some(rate(4.0))),
    ),
    SubscriptionUpdate(
      subscription_id.from_string_unsafe("deleted"),
      rate_response(request, Some(rate(4.0))),
    ),
    SubscriptionUpdate(id, rate_response(request, None)),
    SubscriptionFailed(id, request, RateUnavailable),
  ]

  let unavailable =
    list.fold(responses, pending, fn(model, response) {
      let model = receive_response(model, response) |> snapshot
      assert encoded_state() == previous_url
      assert url_write_count() == previous_writes
      model
    })

  let _ =
    receive_response(
      unavailable,
      SubscriptionUpdate(id, rate_response(request, Some(rate(4.0)))),
    )
  assert saved_state()
    == ClientState([ConverterState(ethereum_id, usd_id, 25.0)])
  assert url_write_count() == previous_writes + 1
}

pub fn left_amount_is_saved_immediately_when_changing_currency_test() {
  use <- with_browser
  let initial = snapshot(model_with_left_amount())
  let previous_writes = url_write_count()

  let pending = select_ethereum(initial)
  assert saved_state()
    == ClientState([ConverterState(ethereum_id, usd_id, 10.0)])
  assert url_write_count() == previous_writes + 1

  let _ =
    receive_response(
      pending,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe(converter_id),
        rate_response(RateRequest(ethereum_id, usd_id), Some(rate(4.0))),
      ),
    )
  assert url_write_count() == previous_writes + 1
}

pub fn ordinary_live_rate_updates_do_not_rewrite_the_url_test() {
  use <- with_browser
  let initial = snapshot(model_with_left_amount())
  let previous_url = encoded_state()
  let previous_writes = url_write_count()

  let _ =
    receive_response(
      initial,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe(converter_id),
        rate_response(RateRequest(bitcoin_id, usd_id), Some(rate(4.0))),
      ),
    )

  assert encoded_state() == previous_url
  assert url_write_count() == previous_writes
}

pub fn snapshots_wait_until_all_calculated_left_amounts_are_available_test() {
  use <- with_browser
  let initial = model_with_right_amount()
  let assert Ok(second) =
    converter.new(
      "converter-2",
      initial.currencies,
      #(ethereum_id, usd_id),
      "25",
      Some(rate(4.0)),
    )
  let second = converter.with_amount(second, Right, "100")
  let initial =
    Model(..initial, converters: list.append(initial.converters, [second]))
    |> snapshot
  let previous_url = encoded_state()
  let previous_writes = url_write_count()

  let pending = select_ethereum(initial)
  let pending =
    update(
      pending,
      client.FromConverter(
        "converter-2",
        converter.UserSelectedCurrency(
          Left,
          Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
        ),
      ),
    )
  let partly_resolved =
    receive_response(
      pending,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe(converter_id),
        rate_response(RateRequest(ethereum_id, usd_id), Some(rate(8.0))),
      ),
    )
  assert encoded_state() == previous_url
  assert url_write_count() == previous_writes

  let _ =
    receive_response(
      partly_resolved,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe("converter-2"),
        rate_response(RateRequest(bitcoin_id, usd_id), Some(rate(5.0))),
      ),
    )
  assert saved_state()
    == ClientState([
      ConverterState(ethereum_id, usd_id, 12.5),
      ConverterState(bitcoin_id, usd_id, 20.0),
    ])
  assert url_write_count() == previous_writes + 1
}

fn model_with_left_amount() -> Model {
  let model =
    client.model_from_page_data(
      PageData(
        currencies: [
          Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
          Crypto(ethereum_id, "Ethereum", "ETH", Some(2)),
          Fiat(usd_id, "US Dollar", "USD", "$"),
        ],
        converters: [ConverterState(bitcoin_id, usd_id, 10.0)],
      ),
    )

  Model(..model, socket: Some(socket()))
  |> receive_response(SubscriptionUpdate(
    subscription_id.from_string_unsafe(converter_id),
    rate_response(RateRequest(bitcoin_id, usd_id), Some(rate(2.0))),
  ))
}

fn model_with_right_amount() -> Model {
  let model = model_with_left_amount()
  let assert [target] = model.converters
  client.model_with_converter(
    model,
    converter.with_amount(target, Right, "100"),
  )
}

fn select_ethereum(model: Model) -> Model {
  update(
    model,
    client.FromConverter(
      converter_id,
      converter.UserSelectedCurrency(
        Left,
        Crypto(ethereum_id, "Ethereum", "ETH", Some(2)),
      ),
    ),
  )
}

fn snapshot(model: Model) -> Model {
  update(model, client.AppScheduledStateSnapshot)
}

fn update(model: Model, message: client.Msg) -> Model {
  let #(updated, _) = client.update(model, message)
  updated
}

fn receive_response(model, response) -> Model {
  let payload =
    response
    |> websocket_response.encode
    |> json.to_string

  update(model, client.FromWebSocket(OnTextMessage(payload)))
}

fn rate_response(request: RateRequest, rate) {
  RateResponse(request.from, request.to, rate, Kraken, 123)
}

fn rate(value: Float) {
  positive_float.from_float_unsafe(value)
}

fn amount(value: Float) {
  non_negative_float.from_float_unsafe(value)
}

fn saved_state() -> ClientState {
  let assert Ok(state) = client_state.decode(encoded_state())
  state
}

/// Runs a synchronous test with isolated `window` and `history` stubs.
/// Restores the previous globals when `run` returns or throws.
@external(javascript, "./url_persistence_test_ffi.mjs", "withBrowser")
fn with_browser(run: fn() -> Nil) -> Nil

/// Returns the active test URL's `state` query parameter, or an empty string
/// when it is absent. Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "encodedState")
fn encoded_state() -> String

/// Returns the number of `history.replaceState` calls in the current
/// `with_browser` scope.
@external(javascript, "./url_persistence_test_ffi.mjs", "urlWriteCount")
fn url_write_count() -> Int

/// Returns a WebSocket test stub with a no-op `send` method.
@external(javascript, "./url_persistence_test_ffi.mjs", "socket")
fn socket() -> WebSocket
