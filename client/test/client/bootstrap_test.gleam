import client.{
  type Model, type Msg, AppScheduledReconnection, FromWebSocket,
  UserClickedAddConverter, UserClickedDeleteConverter,
}
import client/side.{Left, Right}
import client/ui/converter.{Current, Failed, NotTracked, Waiting}
import client/websocket/websocket.{GoingAway, OnClose, OnTextMessage}
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect.{type Effect}
import lustre/element
import shared/client_state.{type ClientState, ClientState, ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/numbers/non_negative_float.{type NonNegativeFloat}
import shared/numbers/positive_float.{type PositiveFloat}
import shared/page_data.{type PageData, PageData}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{type RateResponse, Kraken, RateResponse}
import shared/subscriptions/subscription_id
import shared/websocket_request.{Subscribe}
import shared/websocket_response.{
  type WebsocketResponse, RateUnavailable, SubscriptionFailed,
  SubscriptionUpdate,
}

pub fn startup_preserves_rows_url_and_delayed_loading_test() {
  use <- with_browser
  let encoded =
    page_data()
    |> page_data.encode
    |> json.to_string
  assert !string.contains(encoded, "\"rate\":")
  let assert Ok(data) = json.parse(encoded, page_data.decoder())
  let #(initial, effects) = client.init(data)

  assert saved_state() == ClientState(data.converters)
  assert client.model_to_client_state(initial) == saved_state()
  assert list.map(initial.converters, fn(target) { target.rate_status })
    == [Waiting(1, False), Waiting(2, False), Waiting(3, False)]
  assert initial.next_loading_token == 4
  assert !has_spinner(initial)
  assert !string.contains(render(initial), "price not tracked")
  assert string.contains(render(initial), "rate-indicator-converter-1")
  assert string.contains(render(initial), "btn-info")

  perform(effects)
  assert pending_timer_count() == 3
  advance_time(299)
  assert take_messages() == []
  advance_time(1)
  let visible = deliver_messages(initial)
  assert list.map(visible.converters, fn(target) { target.rate_status })
    == [Waiting(1, True), Waiting(2, True), Waiting(3, True)]
  assert has_spinner(visible)
  assert saved_state() == ClientState(data.converters)
}

pub fn startup_quotes_settle_rows_independently_test() {
  use <- with_browser
  let data =
    PageData(..page_data(), converters: [
      ConverterState(1, 2781, 10.0),
      ConverterState(1027, 2781, 20.0),
      ConverterState(2781, 1, 30.0),
    ])
  let #(initial, effects) = client.init(data)
  perform(effects)
  assert pending_timer_count() == 3
  open_socket()
  let connected = deliver_messages(initial)
  let settled =
    connected
    |> receive_response(SubscriptionUpdate(
      subscription_id.from_string_unsafe("converter-1"),
      quote(1, 2781, Some(rate(2.0))),
    ))
    |> receive_response(SubscriptionUpdate(
      subscription_id.from_string_unsafe("converter-2"),
      quote(1027, 2781, None),
    ))

  let assert [current, untracked, waiting] = settled.converters
  assert current.rate_status == Current
  assert untracked.rate_status == NotTracked
  assert converter.get_converter_input(untracked, Right).amount_input.raw
    == "price not tracked"
  assert waiting.rate_status == Waiting(3, False)

  advance_time(300)
  let visible = deliver_messages(settled)
  let assert [still_current, still_untracked, still_waiting] =
    visible.converters
  assert still_current == current
  assert still_untracked == untracked
  assert still_waiting.rate_status == Waiting(3, True)
}

pub fn websocket_subscribes_all_rows_and_keeps_received_rates_on_reconnect_test() {
  use <- with_browser
  let data = page_data()
  let #(initial, effects) = client.init(data)
  perform(effects)
  open_socket()
  let connected = deliver_messages(initial)
  assert connected.converters == initial.converters
  assert_subscriptions(sent_messages())
  let loaded =
    receive_response(
      connected,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe("converter-1"),
        quote(1, 2781, Some(rate(2.0))),
      ),
    )
  let assert [target, ..] = loaded.converters
  assert target.rate_status == Current

  let disconnected = update(loaded, FromWebSocket(OnClose(GoingAway)))
  assert disconnected.converters == loaded.converters
  let reconnecting = update(disconnected, AppScheduledReconnection)
  open_socket()
  let reconnected = deliver_messages(reconnecting)
  assert reconnected.converters == loaded.converters
  assert_subscriptions(list.drop(sent_messages(), 3))
  assert saved_state() == ClientState(data.converters)
}

pub fn connection_failure_before_first_quote_recovers_without_losing_state_test() {
  use <- with_browser
  let data = page_data()
  let #(initial, effects) = client.init(data)
  perform(effects)

  let disconnected = update(initial, FromWebSocket(OnClose(GoingAway)))
  assert disconnected.converters == initial.converters
  assert saved_state() == ClientState(data.converters)
  assert sent_messages() == []

  // Include the first retry's maximum positive jitter.
  advance_time(1250)
  let reconnecting = deliver_messages(disconnected)
  assert reconnecting.reconnect_attempts == 1
  assert has_spinner(reconnecting)
  assert client.model_to_client_state(reconnecting)
    == ClientState(data.converters)

  open_socket()
  let connected = deliver_messages(reconnecting)
  assert_subscriptions(sent_messages())
  let loaded =
    receive_response(
      connected,
      SubscriptionUpdate(
        subscription_id.from_string_unsafe("converter-1"),
        quote(1, 2781, Some(rate(2.0))),
      ),
    )
  let assert [target, ..] = loaded.converters
  assert target.rate_status == Current
  assert converter.get_parsed_amount(target, Right) == Some(amount(0.00000002))
  assert saved_state() == ClientState(data.converters)
}

pub fn websocket_failure_then_success_preserves_saved_amounts_test() {
  use <- with_browser
  let data = page_data()
  let #(initial, effects) = client.init(data)
  perform(effects)
  open_socket()
  let connected = deliver_messages(initial)
  let id = subscription_id.from_string_unsafe("converter-1")
  let failed =
    receive_response(
      connected,
      SubscriptionFailed(id, RateRequest(1, 2781), RateUnavailable),
    )
  let assert [target, ..] = failed.converters
  assert target.rate_status == Failed(RateUnavailable)
  assert converter.get_parsed_amount(target, Left) == Some(amount(0.00000001))
  assert converter.get_converter_input(target, Right).amount_input.raw == ""
  assert string.contains(
    render(failed),
    "Rate unavailable. Retrying automatically.",
  )
  assert saved_state() == ClientState(data.converters)

  let recovered =
    receive_response(
      failed,
      SubscriptionUpdate(id, quote(1, 2781, Some(rate(2.0)))),
    )
  let assert [target, ..] = recovered.converters
  assert target.rate_status == Current
  assert converter.get_parsed_amount(target, Right) == Some(amount(0.00000002))
  assert !string.contains(render(recovered), "Rate unavailable")
  assert client.model_to_client_state(recovered) == ClientState(data.converters)
  assert saved_state() == ClientState(data.converters)
}

pub fn fast_startup_responses_ignore_the_initial_loading_timer_test() {
  list.each([Some(rate(2.0)), None], fn(price) {
    use <- with_browser
    let data =
      PageData(..page_data(), converters: [ConverterState(1, 2781, 10.0)])
    let #(initial, effects) = client.init(data)
    perform(effects)
    let settled =
      receive_response(
        initial,
        SubscriptionUpdate(
          subscription_id.from_string_unsafe("converter-1"),
          quote(1, 2781, price),
        ),
      )
    advance_time(300)
    assert deliver_messages(settled) == settled
    assert !has_spinner(settled)
  })
}

pub fn startup_loading_timer_does_not_affect_a_reused_converter_id_test() {
  use <- with_browser
  let data =
    PageData(..page_data(), converters: [ConverterState(1, 2781, 10.0)])
  let #(initial, effects) = client.init(data)
  perform(effects)
  advance_time(100)
  let removed = update(initial, UserClickedDeleteConverter("converter-1"))
  let added = update(removed, UserClickedAddConverter)
  let assert [target] = added.converters
  assert target.id == "converter-1"
  assert target.rate_status == Waiting(2, False)

  advance_time(200)
  assert deliver_messages(added) == added
  advance_time(100)
  let visible = deliver_messages(added)
  let assert [target] = visible.converters
  assert target.rate_status == Waiting(2, True)
}

pub fn waiting_converters_still_allow_adding_a_converter_test() {
  use <- with_browser
  let data = page_data()
  let #(initial, effects) = client.init(data)
  perform(effects)
  open_socket()
  let connected = deliver_messages(initial)

  // Keep the existing rows and append a converter with the default state.
  let updated = update(connected, UserClickedAddConverter)
  let assert [first, second, third, new_converter] = updated.converters
  assert [first, second, third] == connected.converters
  assert new_converter.id == "converter-4"
  assert converter.get_selected_currency_id(new_converter, Left) == 1
  assert converter.get_selected_currency_id(new_converter, Right) == 2781
  assert converter.get_parsed_amount(new_converter, Left) == Some(amount(1.0))
  assert new_converter.rate_status == Waiting(4, False)

  // Send one new subscription after the three startup subscriptions.
  let assert [_, _, _, subscription_message] = sent_messages()
  let assert Ok(Subscribe([subscription])) =
    json.parse(subscription_message, websocket_request.decoder())
  assert subscription_id.to_string(subscription.id) == "converter-4"
  assert subscription.rate_request == RateRequest(1, 2781)

  // Persist the new converter alongside the original state.
  let expected_converters =
    list.append(data.converters, [ConverterState(1, 2781, 1.0)])
  assert saved_state() == ClientState(expected_converters)
}

fn page_data() -> PageData {
  PageData(
    currencies: [
      Crypto(1, "Bitcoin", "BTC", Some(1)),
      Crypto(1027, "Ethereum", "ETH", Some(2)),
      Fiat(2781, "US Dollar", "USD", "$"),
    ],
    converters: [
      ConverterState(1, 2781, 0.00000001),
      ConverterState(1027, 2781, 20.0),
      ConverterState(1, 2781, 30.0),
    ],
  )
}

fn quote(from, to, rate) -> RateResponse {
  RateResponse(from, to, rate, Kraken, 123)
}

fn rate(value: Float) -> PositiveFloat {
  positive_float.from_float_unsafe(value)
}

fn amount(value: Float) -> NonNegativeFloat {
  non_negative_float.from_float_unsafe(value)
}

fn saved_state() -> ClientState {
  let assert Ok(state) = client_state.decode(encoded_state())
  state
}

fn assert_subscriptions(messages: List(String)) -> Nil {
  let subscriptions =
    list.flat_map(messages, fn(message) {
      let assert Ok(Subscribe(requests)) =
        json.parse(message, websocket_request.decoder())
      requests
    })
    |> list.sort(fn(a, b) {
      string.compare(
        subscription_id.to_string(a.id),
        subscription_id.to_string(b.id),
      )
    })
  assert list.map(subscriptions, fn(request) {
      #(subscription_id.to_string(request.id), request.rate_request)
    })
    == [
      #("converter-1", RateRequest(1, 2781)),
      #("converter-2", RateRequest(1027, 2781)),
      #("converter-3", RateRequest(1, 2781)),
    ]
}

fn update(model: Model, message: Msg) -> Model {
  let #(model, effects) = client.update(model, message)
  perform(effects)
  model
}

fn receive_response(model: Model, response: WebsocketResponse) -> Model {
  update(
    model,
    FromWebSocket(OnTextMessage(
      response
      |> websocket_response.encode
      |> json.to_string,
    )),
  )
}

fn perform(effects: Effect(Msg)) -> Nil {
  effect.perform(
    effects,
    record_message,
    fn(_, _) { Nil },
    fn(_) { Nil },
    dynamic.nil,
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
}

fn deliver_messages(model: Model) -> Model {
  list.fold(take_messages(), model, update)
}

fn render(model: Model) -> String {
  model
  |> client.view
  |> element.to_string
}

fn has_spinner(model: Model) -> Bool {
  string.contains(render(model), "aria-label=\"Loading rate\"")
}

/// Runs a synchronous test with isolated `window` and `history` stubs.
/// Restores the previous globals when `run` returns or throws.
@external(javascript, "./url_persistence_test_ffi.mjs", "withBrowser")
fn with_browser(run: fn() -> Nil) -> Nil

/// Returns the active test URL's `state` query parameter, or an empty string
/// when it is absent. Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "encodedState")
fn encoded_state() -> String

/// Queues a message dispatched by an effect for later delivery to the model.
/// Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "recordMessage")
fn record_message(message: Msg) -> Nil

/// Returns queued messages in dispatch order and clears the message queue.
/// Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "takeMessages")
fn take_messages() -> List(Msg)

/// Returns recorded outgoing WebSocket messages in send order without clearing them.
/// Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "sentMessages")
fn sent_messages() -> List(String)

/// Fires the open callback on the most recently created WebSocket stub.
/// Must follow socket initialization within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "openSocket")
fn open_socket() -> Nil

/// Returns the number of scheduled fake timers that have not fired.
/// Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "pendingTimerCount")
fn pending_timer_count() -> Int

/// Advances the fake clock by `milliseconds`, firing all due timers in order.
/// Call `deliver_messages` afterward to apply any messages queued by the callbacks.
/// Must be called within `with_browser`.
@external(javascript, "./url_persistence_test_ffi.mjs", "advanceTime")
fn advance_time(milliseconds: Int) -> Nil
