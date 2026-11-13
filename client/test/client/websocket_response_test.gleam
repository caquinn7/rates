import client.{type Model, Model}
import client/side.{type Side, Left, Right}
import client/ui/auto_resize_input.{type InputEvent, InputEvent}
import client/ui/converter.{
  type AmountInput, type Converter, Current, Failed, NotTracked, Waiting,
}
import client/websocket/websocket.{OnTextMessage}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/numbers/non_negative_float
import shared/numbers/positive_float.{type PositiveFloat}
import shared/page_data.{PageData}
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}
import shared/subscriptions/subscription_id
import shared/websocket_response.{
  type SubscriptionError, type WebsocketResponse, CurrencyNotFound,
  ProtocolError, RateUnavailable, SubscriptionFailed, SubscriptionUpdate,
}

const bitcoin_id = 1

const ethereum_id = 1027

const usd_id = 2781

const bitcoin_converter_id = "converter-1"

pub fn rate_failure_only_updates_the_matching_converter_test() {
  let initial_model = model_with_two_converters()
  let assert [initial_bitcoin, initial_ethereum] = initial_model.converters
  let response =
    rate_failure(
      bitcoin_converter_id,
      RateRequest(bitcoin_id, usd_id),
      RateUnavailable,
    )

  let updated_model = receive_response(initial_model, response)
  let assert [updated_bitcoin, updated_ethereum] = updated_model.converters

  assert updated_bitcoin.rate_status == Failed(RateUnavailable)
  assert updated_bitcoin.rate == initial_bitcoin.rate
  assert updated_bitcoin.inputs == initial_bitcoin.inputs
  assert updated_ethereum == initial_ethereum

  let rendered_page =
    updated_model
    |> client.view
    |> element.to_string

  assert string.contains(
    rendered_page,
    "Using last known rate. Rate unavailable. Retrying automatically.",
  )
  assert string.contains(rendered_page, "role=\"status\"")
}

pub fn responses_for_a_previous_currency_pair_are_ignored_test() {
  let initial_model = model_with_two_converters()
  let previous_pair = RateRequest(ethereum_id, usd_id)
  let ignored_responses = [
    rate_failure(
      bitcoin_converter_id,
      previous_pair,
      CurrencyNotFound(ethereum_id),
    ),
    rate_update(bitcoin_converter_id, previous_pair, Some(positive_rate(3.0))),
  ]

  list.each(ignored_responses, fn(response) {
    assert receive_response(initial_model, response) == initial_model
  })
}

pub fn responses_for_a_deleted_converter_are_ignored_test() {
  let initial_model = model_with_two_converters()
  let pair = RateRequest(bitcoin_id, usd_id)
  let ignored_responses = [
    rate_failure("deleted-converter", pair, RateUnavailable),
    rate_update("deleted-converter", pair, Some(positive_rate(3.0))),
  ]

  list.each(ignored_responses, fn(response) {
    assert receive_response(initial_model, response) == initial_model
  })
}

pub fn failure_before_the_first_rate_preserves_the_entered_amount_test() {
  let initial_model = model_with_two_converters()
  let assert [bitcoin, ethereum] = initial_model.converters
  let waiting_bitcoin = converter.waiting_for_rate(bitcoin)
  let waiting_model =
    Model(..initial_model, converters: [waiting_bitcoin, ethereum])
  let response =
    rate_failure(
      bitcoin_converter_id,
      RateRequest(bitcoin_id, usd_id),
      CurrencyNotFound(bitcoin_id),
    )

  let updated_model = receive_response(waiting_model, response)
  let assert [failed_bitcoin, _] = updated_model.converters

  assert failed_bitcoin.rate == None
  assert failed_bitcoin.rate_status == Failed(CurrencyNotFound(bitcoin_id))
  assert_parsed_amount(failed_bitcoin, Left, 10.0)
  assert amount_input(failed_bitcoin, Right).raw == ""

  let rendered_converter = failed_bitcoin |> converter.view |> element.to_string
  assert string.contains(
    rendered_converter,
    "Unable to load this currency right now.",
  )
  assert !string.contains(rendered_converter, "price not tracked")
  assert !string.contains(rendered_converter, "Using last known rate")
}

pub fn successful_rate_update_clears_the_error_test() {
  let pair = RateRequest(bitcoin_id, usd_id)
  let failed_model =
    model_with_two_converters()
    |> receive_response(rate_failure(
      bitcoin_converter_id,
      pair,
      RateUnavailable,
    ))

  let recovered_model =
    receive_response(
      failed_model,
      rate_update(bitcoin_converter_id, pair, Some(positive_rate(4.0))),
    )
  let assert [recovered_bitcoin, _] = recovered_model.converters

  assert recovered_bitcoin.rate_status == Current
  assert_parsed_amount(recovered_bitcoin, Right, 40.0)

  let rendered_converter =
    recovered_bitcoin
    |> converter.view
    |> element.to_string
  assert !string.contains(rendered_converter, "last known")
}

pub fn missing_price_clears_the_error_and_shows_price_not_tracked_test() {
  let pair = RateRequest(bitcoin_id, usd_id)
  let failed_model =
    model_with_two_converters()
    |> receive_response(rate_failure(
      bitcoin_converter_id,
      pair,
      RateUnavailable,
    ))

  let updated_model =
    receive_response(
      failed_model,
      rate_update(bitcoin_converter_id, pair, None),
    )
  let assert [untracked_bitcoin, _] = updated_model.converters

  assert untracked_bitcoin.rate_status == NotTracked
  assert amount_input(untracked_bitcoin, Right).raw == "price not tracked"
}

pub fn rate_failure_preserves_pending_edits_and_stale_conversions_test() {
  let cases = [#(Left, 246.0), #(Right, 61.5)]

  list.each(cases, fn(test_case) {
    let #(edited_side, expected_conversion) = test_case
    let calculated_side = side.opposite_side(edited_side)
    let initial_model = model_with_two_converters()
    let assert [bitcoin, ethereum] = initial_model.converters
    let #(pending_bitcoin, revision) =
      enter_pending_amount(bitcoin, edited_side, "123.")
    let editing_model =
      Model(..initial_model, converters: [pending_bitcoin, ethereum])
    let response =
      rate_failure(
        bitcoin_converter_id,
        RateRequest(bitcoin_id, usd_id),
        RateUnavailable,
      )

    let failed_model = receive_response(editing_model, response)
    let assert [failed_bitcoin, _] = failed_model.converters
    assert failed_bitcoin.inputs == pending_bitcoin.inputs

    let #(committed_bitcoin, _) =
      converter.update(
        failed_bitcoin,
        converter.AmountCommitDue(edited_side, revision),
      )

    assert committed_bitcoin.rate_status == Failed(RateUnavailable)
    assert_parsed_amount(committed_bitcoin, edited_side, 123.0)
    assert_parsed_amount(
      committed_bitcoin,
      calculated_side,
      expected_conversion,
    )
  })
}

pub fn changing_currency_clears_rate_and_error_and_invalidates_edit_timer_test() {
  list.each([Left, Right], fn(edited_side) {
    let calculated_side = side.opposite_side(edited_side)
    let assert [bitcoin, _] = model_with_two_converters().converters
    let failed_bitcoin = converter.with_rate_error(bitcoin, RateUnavailable)
    let #(pending_bitcoin, revision) =
      enter_pending_amount(failed_bitcoin, edited_side, "123.")

    let changed_converter =
      converter.with_selected_currency(
        pending_bitcoin,
        Left,
        Crypto(3, "Other", "OTH", None),
      )

    assert changed_converter.rate == None
    assert changed_converter.rate_status == Waiting(0, False)
    assert changed_converter.last_edited == edited_side
    assert_parsed_amount(changed_converter, edited_side, 123.0)
    assert amount_input(changed_converter, calculated_side).raw == ""

    let outdated_timer = converter.AmountCommitDue(edited_side, revision)
    assert converter.update(changed_converter, outdated_timer)
      == #(changed_converter, converter.NoEffect)
  })
}

pub fn selecting_the_same_currency_preserves_rate_and_error_test() {
  let assert [bitcoin, _] = model_with_two_converters().converters
  let failed_bitcoin = converter.with_rate_error(bitcoin, RateUnavailable)

  let unchanged_converter =
    converter.with_selected_currency(
      failed_bitcoin,
      Left,
      Crypto(bitcoin_id, "Bitcoin", "BTC", None),
    )

  assert unchanged_converter.rate == failed_bitcoin.rate
  assert unchanged_converter.rate_status == failed_bitcoin.rate_status
}

pub fn protocol_errors_are_visible_and_clear_after_a_valid_response_test() {
  let initial_model = model_with_two_converters()
  let models_with_errors = [
    receive_response(initial_model, ProtocolError),
    receive_text_message(initial_model, "not JSON"),
  ]

  list.each(models_with_errors, fn(failed_model) {
    assert failed_model.protocol_error
    assert failed_model.converters == initial_model.converters

    let rendered_page =
      failed_model
      |> client.view
      |> element.to_string

    assert string.contains(
      rendered_page,
      "Unable to update live rates. Reload the page.",
    )

    let recovered_model =
      receive_response(
        failed_model,
        rate_update(
          bitcoin_converter_id,
          RateRequest(bitcoin_id, usd_id),
          Some(positive_rate(4.0)),
        ),
      )

    assert !recovered_model.protocol_error
  })
}

fn model_with_two_converters() -> Model {
  // Simple fixture rates: 10 BTC = 20 USD, and 20 ETH = 60 USD.
  let page_data =
    PageData(
      currencies: [
        Crypto(bitcoin_id, "Bitcoin", "BTC", None),
        Crypto(ethereum_id, "Ethereum", "ETH", None),
        Fiat(usd_id, "US Dollar", "USD", "$"),
      ],
      converters: [
        ConverterState(bitcoin_id, usd_id, 10.0),
        ConverterState(ethereum_id, usd_id, 20.0),
      ],
    )
  let model = client.model_from_page_data(page_data)
  let model =
    model
    |> receive_response(rate_update(
      bitcoin_converter_id,
      RateRequest(bitcoin_id, usd_id),
      Some(positive_rate(2.0)),
    ))
    |> receive_response(rate_update(
      "converter-2",
      RateRequest(ethereum_id, usd_id),
      Some(positive_rate(3.0)),
    ))
  // Let the initial quote indicators settle before testing later events.
  let #(model, _) =
    client.update(
      model,
      client.AppScheduledRateChangeIndicatorReset(bitcoin_converter_id, Right),
    )
  let #(model, _) =
    client.update(
      model,
      client.AppScheduledRateChangeIndicatorReset("converter-2", Right),
    )
  model
}

fn enter_pending_amount(
  target: Converter,
  edited_side: Side,
  draft: String,
) -> #(Converter, Int) {
  let displayed_amount = amount_input(target, edited_side).raw
  let #(focused, _) =
    converter.update(
      target,
      converter.UserFocusedAmount(edited_side, input_event(displayed_amount)),
    )
  let assert #(pending, converter.ScheduleAmountCommit(_, revision)) =
    converter.update(
      focused,
      converter.UserEnteredAmount(edited_side, input_event(draft)),
    )
  #(pending, revision)
}

fn amount_input(target: Converter, side: Side) -> AmountInput {
  converter.get_converter_input(target, side).amount_input
}

fn assert_parsed_amount(target: Converter, side: Side, expected: Float) -> Nil {
  assert amount_input(target, side).parsed
    == Some(non_negative_float.from_float_unsafe(expected))
}

fn positive_rate(value: Float) -> PositiveFloat {
  positive_float.from_float_unsafe(value)
}

fn input_event(value: String) -> InputEvent {
  InputEvent(value, 0, string.length(value))
}

fn rate_failure(
  converter_id: String,
  request: RateRequest,
  error: SubscriptionError,
) -> WebsocketResponse {
  SubscriptionFailed(
    subscription_id.from_string_unsafe(converter_id),
    request,
    error,
  )
}

fn rate_update(
  converter_id: String,
  request: RateRequest,
  rate: Option(PositiveFloat),
) -> WebsocketResponse {
  SubscriptionUpdate(
    subscription_id.from_string_unsafe(converter_id),
    RateResponse(request.from, request.to, rate, Kraken, 123),
  )
}

fn receive_response(model: Model, response: WebsocketResponse) -> Model {
  receive_text_message(
    model,
    response
      |> websocket_response.encode
      |> json.to_string,
  )
}

fn receive_text_message(model: Model, payload: String) -> Model {
  let #(updated_model, _) =
    client.update(model, client.FromWebSocket(OnTextMessage(payload)))

  updated_model
}
