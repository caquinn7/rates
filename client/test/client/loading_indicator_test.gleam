import client.{type Model}
import client/ui/converter.{Converter, Waiting}
import client/websocket/websocket.{OnTextMessage}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/numbers/positive_float
import shared/page_data.{PageData}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}
import shared/subscriptions/subscription_id
import shared/websocket_response.{
  CurrencyNotFound, RateUnavailable, SubscriptionFailed, SubscriptionUpdate,
}

const converter_id = "converter-1"

pub fn loading_spinner_replaces_equals_only_after_its_timer_fires_test() {
  let pending = loading_model(1)
  assert !has_loading_spinner(pending)
  assert has_equal_sign(pending)

  let visible = deliver_loading_timer(pending, 1)
  let assert [target] = visible.converters
  assert target.rate == None
  assert target.rate_status == Waiting(1, True)
  assert has_loading_spinner(visible)
  assert !has_equal_sign(visible)
  assert !string.contains(render(visible), "Waiting for a rate")
}

pub fn fast_rate_responses_never_show_the_spinner_test() {
  list.each([Some(positive_float.from_float_unsafe(2.0)), None], fn(rate) {
    let resolved = receive_response(loading_model(1), rate_update(rate))

    assert deliver_loading_timer(resolved, 1) == resolved
    assert !has_loading_spinner(resolved)
    assert has_equal_sign(resolved)
  })
}

pub fn errors_are_visible_immediately_and_ignore_the_loading_timer_test() {
  let cases = [
    #(CurrencyNotFound(1), "Unable to load this currency right now."),
    #(RateUnavailable, "Rate unavailable. Retrying automatically."),
  ]

  list.each(cases, fn(test_case) {
    let #(error, message) = test_case
    let failed =
      receive_response(
        loading_model(1),
        SubscriptionFailed(
          subscription_id.from_string_unsafe(converter_id),
          RateRequest(1, 2781),
          error,
        ),
      )

    assert string.contains(render(failed), message)
    assert !has_loading_spinner(failed)
    assert has_equal_sign(failed)
    assert deliver_loading_timer(failed, 1) == failed
  })
}

pub fn arriving_rate_restores_equals_immediately_test() {
  let visible = deliver_loading_timer(loading_model(1), 1)
  let resolved =
    receive_response(
      visible,
      rate_update(Some(positive_float.from_float_unsafe(2.0))),
    )

  assert !has_loading_spinner(resolved)
  assert has_equal_sign(resolved)
}

pub fn a_timer_from_an_earlier_request_does_not_show_the_spinner_test() {
  let newer_request = loading_model(2)

  assert deliver_loading_timer(newer_request, 1) == newer_request
  assert !has_loading_spinner(newer_request)
  assert has_equal_sign(newer_request)
}

pub fn a_timer_for_a_deleted_converter_is_ignored_test() {
  let removed = client.Model(..loading_model(1), converters: [])

  assert deliver_loading_timer(removed, 1) == removed
}

fn loading_model(token: Int) -> Model {
  let assert Ok(model) =
    client.model_from_page_data(
      PageData(
        currencies: [
          Crypto(1, "Bitcoin", "BTC", None),
          Fiat(2781, "US Dollar", "USD", "$"),
        ],
        rates: [
          RateResponse(
            1,
            2781,
            Some(positive_float.from_float_unsafe(2.0)),
            Kraken,
            123,
          ),
        ],
        converters: [ConverterState(1, 2781, 10.0)],
      ),
    )
  let assert [target] = model.converters
  let target = converter.waiting_for_rate(target)
  let target = Converter(..target, rate_status: Waiting(token, False))
  client.Model(..model, converters: [target], next_loading_token: token + 1)
}

fn deliver_loading_timer(model: Model, token: Int) -> Model {
  let #(updated, _) =
    client.update(
      model,
      client.AppScheduledLoadingIndicator(converter_id, token),
    )
  updated
}

fn rate_update(rate) {
  SubscriptionUpdate(
    subscription_id.from_string_unsafe(converter_id),
    RateResponse(1, 2781, rate, Kraken, 123),
  )
}

fn receive_response(model, response) {
  let payload =
    response
    |> websocket_response.encode
    |> json.to_string

  let #(updated, _) =
    client.update(model, client.FromWebSocket(OnTextMessage(payload)))

  updated
}

fn has_loading_spinner(model: Model) -> Bool {
  string.contains(render(model), "aria-label=\"Loading rate\"")
}

fn has_equal_sign(model: Model) -> Bool {
  string.contains(render(model), ">=</span>")
}

fn render(model: Model) -> String {
  model
  |> client.view
  |> element.to_string
}
