import client/browser/document
import client/browser/element as browser_element
import client/browser/event as browser_event
import client/currency/collection.{type CurrencyCollection} as currency_collection
import client/currency/formatting as currency_formatting
import client/positive_float.{type PositiveFloat}
import client/rates/rate_request
import client/rates/rate_response
import client/side.{type Side, Left, Right}
import client/socket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import client/start_data.{type StartData}
import client/ui/button_dropdown.{DropdownOption}
import client/ui/components/auto_resize_input
import gleam/bool
import gleam/int
import gleam/javascript/array
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import shared/currency.{type Currency} as _shared_currency
import shared/rates/rate_request.{type RateRequest, RateRequest} as _shared_rate_request
import shared/rates/rate_response.{RateResponse} as _shared_rate_response

pub type Model {
  Model(
    currencies: List(Currency),
    conversion: Conversion,
    socket: Option(WebSocket),
  )
}

pub type Conversion {
  Conversion(
    conversion_inputs: #(ConversionInput, ConversionInput),
    rate: Option(PositiveFloat),
    last_edited: Side,
  )
}

pub type ConversionInput {
  ConversionInput(
    amount_input: AmountInput,
    currency_selector: CurrencySelector,
  )
}

pub type AmountInput {
  AmountInput(raw: String, parsed: Option(PositiveFloat))
}

pub type CurrencySelector {
  CurrencySelector(
    id: String,
    show_dropdown: Bool,
    currency_filter: String,
    currencies: CurrencyCollection,
    selected_currency: Currency,
    focused_index: Option(Int),
  )
}

// model utility functions

pub fn map_conversion_input(
  model: Model,
  side: Side,
  fun: fn(ConversionInput) -> a,
) -> a {
  let target = case side {
    Left -> model.conversion.conversion_inputs.0
    Right -> model.conversion.conversion_inputs.1
  }
  fun(target)
}

pub fn map_conversion_inputs(
  inputs: #(ConversionInput, ConversionInput),
  side: Side,
  fun: fn(ConversionInput) -> ConversionInput,
) -> #(ConversionInput, ConversionInput) {
  let map_pair = case side {
    Left -> pair.map_first
    Right -> pair.map_second
  }
  map_pair(inputs, fun)
}

/// Updates the model in response to a new exchange rate.
///
/// If the user previously entered a valid amount on one side (tracked by `last_edited`),
/// this function:
/// - Calculates the converted value for the opposite side using the new rate
/// - Updates the `amount_input` on the opposite side accordingly
///
/// If no valid parsed input is present, only the rate is updated.
///
/// This function ensures that the conversion remains accurate when the rate changes,
/// while preserving the user’s original input.
pub fn model_with_rate(model: Model, rate: PositiveFloat) -> Model {
  // When a new exchange rate comes in, we want to:
  // - Recalculate the opposite input field if the user previously entered a number
  // - Leave the inputs unchanged if there’s no valid parsed input
  // - Always update the stored rate

  let edited_side = model.conversion.last_edited

  // Try to get the parsed amount from the side the user last edited
  let edited_side_parsed_amount =
    map_conversion_input(model, edited_side, fn(input) {
      input.amount_input.parsed
    })

  // Decide how to update the inputs based on whether we have a parsed amount
  let updated_inputs = case edited_side_parsed_amount {
    None -> model.conversion.conversion_inputs

    Some(parsed_amount) -> {
      // Compute the value for the *opposite* field using the new rate
      let converted_amount = case edited_side {
        // converting from left to right
        Left -> positive_float.multiply(parsed_amount, rate)
        // converting from right to left
        Right ->
          case positive_float.try_divide(parsed_amount, rate) {
            Error(_) -> panic as "rate should not be zero"
            Ok(x) -> x
          }
      }

      // Update only the opposite side’s amount_input field with the converted value
      model.conversion.conversion_inputs
      |> map_conversion_inputs(side.opposite_side(edited_side), fn(input) {
        ConversionInput(
          ..input,
          amount_input: AmountInput(
            raw: currency_formatting.format_currency_amount(
              input.currency_selector.selected_currency,
              converted_amount,
            ),
            parsed: Some(converted_amount),
          ),
        )
      })
    }
  }

  let updated_conversion =
    Conversion(
      ..model.conversion,
      conversion_inputs: updated_inputs,
      rate: Some(rate),
    )

  Model(..model, conversion: updated_conversion)
}

/// Updates the model in response to user input in the amount field.
///
/// Attempts to parse the `raw_amount` string into a float. If successful, it:
/// - Updates the `amount_input` on the edited side with the parsed value
/// - Computes the converted amount for the opposite side using the current exchange rate
///
/// If parsing fails:
/// - Clears the input on the opposite side
///
/// Always updates the `last_edited` field in the model’s conversion state.
///
/// This function ensures that the two conversion inputs stay in sync
/// while allowing user-friendly behavior like partial decimal input and
/// comma separators.
pub fn model_with_amount(model: Model, side: Side, raw_amount: String) -> Model {
  let conversion_inputs = model.conversion.conversion_inputs

  let map_failed_parse = fn() {
    // Set the raw string on the edited side, clear the parsed value
    conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        amount_input: AmountInput(raw: raw_amount, parsed: None),
      )
    })
    // Clear the raw and parsed value on the opposite side
    |> map_conversion_inputs(side.opposite_side(side), fn(input) {
      ConversionInput(..input, amount_input: AmountInput(raw: "", parsed: None))
    })
  }

  let map_successful_parse = fn(raw_amount, parsed_amount) {
    // Update the side the user edited with the parsed and formatted value
    conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        amount_input: AmountInput(raw: raw_amount, parsed: Some(parsed_amount)),
      )
    })
    // Compute and set the converted amount on the opposite side if a rate is available
    |> map_conversion_inputs(side.opposite_side(side), fn(input) {
      let rate = model.conversion.rate
      let maybe_converted_amount = case side {
        Left -> option.map(rate, positive_float.multiply(parsed_amount, _))
        Right ->
          option.map(rate, fn(positive_float) {
            case positive_float.try_divide(parsed_amount, positive_float) {
              Ok(x) -> x
              _ -> panic as "rate should not be zero"
            }
          })
      }

      ConversionInput(
        ..input,
        amount_input: maybe_converted_amount
          |> option.map(fn(converted) {
            AmountInput(
              raw: currency_formatting.format_currency_amount(
                input.currency_selector.selected_currency,
                converted,
              ),
              parsed: Some(converted),
            )
          })
          |> option.unwrap(AmountInput(raw: "", parsed: None)),
      )
    })
  }

  let updated_inputs = case positive_float.parse(raw_amount) {
    Error(_) -> map_failed_parse()
    Ok(amount) -> map_successful_parse(raw_amount, amount)
  }

  Model(
    ..model,
    conversion: Conversion(
      ..model.conversion,
      conversion_inputs: updated_inputs,
      last_edited: side,
    ),
  )
}

/// Toggles the visibility of the currency selector dropdown for the given side.
pub fn toggle_currency_selector_dropdown(model: Model, side: Side) -> Model {
  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(side, fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          show_dropdown: !conversion_input.currency_selector.show_dropdown,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

pub fn model_with_focused_index(
  model: Model,
  side: Side,
  get_next_index: fn() -> Option(Int),
) {
  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        currency_selector: CurrencySelector(
          ..input.currency_selector,
          focused_index: get_next_index(),
        ),
      )
    })

  Model(
    ..model,
    conversion: Conversion(
      ..model.conversion,
      conversion_inputs: conversion_inputs,
    ),
  )
}

pub type NavKey {
  ArrowUp
  ArrowDown
  Enter
  Other(String)
}

/// Calculates the next focused index for keyboard navigation in a currency selector dropdown.
///
/// Given the current index, a navigation key (`ArrowDown`, `ArrowUp`, etc.), and the number of options,
/// returns the new focused index according to the following rules:
/// - If `option_count` is zero, returns `None`.
/// - If the current index is set, moves up or down (with wrap-around) for arrow keys.
/// - If the current index is `None`, sets to `0` for `ArrowDown` or to the last index for `ArrowUp`.
/// - For other keys, returns the current index unchanged.
pub fn calculate_next_focused_index(
  current_index: Option(Int),
  key: NavKey,
  option_count: Int,
) -> Option(Int) {
  use <- bool.guard(option_count == 0, None)

  current_index
  |> option.map(fn(index) {
    case key {
      ArrowDown -> { index + 1 } % option_count
      ArrowUp -> { index - 1 + option_count } % option_count
      _ -> index
    }
  })
  |> option.or(case key {
    ArrowDown -> Some(0)
    ArrowUp -> Some(option_count - 1)
    _ -> None
  })
}

pub fn navigate_currency_selector(
  model: Model,
  side: Side,
  key: NavKey,
) -> #(Model, Effect(Msg)) {
  let model = {
    let currency_selector =
      map_conversion_input(model, side, fn(input) { input.currency_selector })

    model_with_focused_index(model, side, fn() {
      calculate_next_focused_index(
        currency_selector.focused_index,
        key,
        currency_collection.length(currency_selector.currencies),
      )
    })
  }

  let focused_index =
    map_conversion_input(model, side, fn(input) {
      input.currency_selector.focused_index
    })

  let effect = case focused_index {
    None -> effect.none()

    Some(index) ->
      effect.before_paint(fn(_, _) {
        let currency_selector_id =
          map_conversion_input(model, side, fn(input) {
            input.currency_selector.id
          })

        let option_elems =
          document.query_selector_all(
            "#"
            <> currency_selector_id
            <> " .options-container"
            <> " .dd-option",
          )

        let assert Ok(target_option_elem) = array.get(option_elems, index)
        let _ = browser_element.scroll_into_view(target_option_elem)

        Nil
      })
  }

  #(model, effect)
}

pub fn select_currency_via_enter_key(
  model: Model,
  side: Side,
) -> #(Model, Effect(Msg)) {
  let #(focused_index, currencies) =
    map_conversion_input(model, side, fn(input) {
      let selector = input.currency_selector
      #(selector.focused_index, selector.currencies)
    })

  let model = case focused_index {
    None -> model

    Some(index) -> {
      let assert Ok(selected_currency) =
        currencies
        |> currency_collection.at_index(index)

      model
      |> model_with_selected_currency(side, selected_currency)
      |> toggle_currency_selector_dropdown(side)
    }
  }

  let effect = try_subscribe_to_rate_updates(model)

  #(model, effect)
}

/// Checks if the given currency matches the provided filter string.
/// The match is case-insensitive and is performed against both the currency's name and symbol.
/// Returns `True` if either the name or symbol contains the filter string, otherwise returns `False`.
///
/// # Arguments
/// - `currency`: The currency to check.
/// - `filter_str`: The filter string to match against the currency's name and symbol.
///
/// # Example
/// ```gleam
/// let usd = Fiat(id: 2781, name: "US Dollar", symbol: "USD", sign: "$")
/// currency_matches_filter(usd, "usd") // Returns: True
/// currency_matches_filter(usd, "dollar") // Returns: True
/// currency_matches_filter(usd, "eur") // Returns: False
/// ```
pub fn currency_matches_filter(currency: Currency, filter_str: String) -> Bool {
  let is_match = fn(str) {
    str
    |> string.lowercase
    |> string.contains(string.lowercase(filter_str))
  }

  is_match(currency.name) || is_match(currency.symbol)
}

/// Updates the given `model` by applying a currency filter to its currencies and conversion inputs.
/// 
/// - `model`: The current `Model` to update.
/// - `side`: The `Side` to use for conversion input mapping.
/// - `filter_str`: The string used to filter currencies.
/// - `match_fun`: A function that determines if a `Currency` matches the filter string.
/// 
/// Returns a new `Model` with filtered currencies and updated conversion inputs reflecting the filter.
pub fn model_with_currency_filter(
  model: Model,
  side: Side,
  filter_str: String,
  currency_matches: fn(Currency, String) -> Bool,
) -> Model {
  let currencies =
    model.currencies
    |> list.filter(currency_matches(_, filter_str))
    |> currency_collection.from_list

  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(side, fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          currency_filter: filter_str,
          currencies:,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

/// Updates the selected currency for the specified side.
///
/// Replaces the currently selected currency in the `currency_selector`
/// with the provided `currency`.
///
/// Ued when the user selects a currency from the dropdown.
pub fn model_with_selected_currency(
  model: Model,
  side: Side,
  currency: Currency,
) {
  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(side, fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          selected_currency: currency,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

// end model utility functions

pub fn main() -> Nil {
  let assert Ok(json_str) =
    document.query_selector("#model")
    |> result.map(browser_element.inner_text)

  let start_data = case json.parse(json_str, start_data.decoder()) {
    Ok(start_data) -> start_data
    _ -> panic as "failed to decode start_data"
  }

  let assert Ok(_) = auto_resize_input.register("auto-resize-input")

  let app = lustre.application(init, update, view)
  let assert Ok(runtime) = lustre.start(app, "#app", start_data)

  document.add_event_listener("click", fn(event) {
    event
    |> UserClickedInDocument
    |> lustre.dispatch
    |> lustre.send(runtime, _)
  })
}

pub fn init(flags: StartData) -> #(Model, Effect(Msg)) {
  #(model_from_start_data(flags), socket.init("/ws", WsWrapper))
}

pub fn model_from_start_data(start_data: StartData) {
  let RateResponse(from, to, rate, _source) = start_data.rate

  let assert Ok(from_currency) =
    start_data.currencies
    |> list.find(fn(c) { c.id == from })

  let assert Ok(to_currency) =
    start_data.currencies
    |> list.find(fn(c) { c.id == to })

  let currencies =
    start_data.currencies
    |> currency_collection.from_list

  let make_selector = fn(side: Side, currency: Currency) {
    CurrencySelector(
      id: "currency-selector-" <> side.to_string(side),
      show_dropdown: False,
      currency_filter: "",
      currencies:,
      selected_currency: currency,
      focused_index: None,
    )
  }

  let left_input =
    ConversionInput(
      amount_input: AmountInput(
        raw: "1",
        parsed: Some(positive_float.from_float_unsafe(1.0)),
      ),
      currency_selector: make_selector(Left, from_currency),
    )

  let right_input =
    ConversionInput(
      amount_input: AmountInput(
        raw: currency_formatting.format_currency_amount(
          to_currency,
          positive_float.from_float_unsafe(rate),
        ),
        parsed: Some(positive_float.from_float_unsafe(rate)),
      ),
      currency_selector: make_selector(Right, to_currency),
    )

  Model(
    currencies: start_data.currencies,
    conversion: Conversion(
      conversion_inputs: #(left_input, right_input),
      rate: Some(positive_float.from_float_unsafe(rate)),
      last_edited: Left,
    ),
    socket: None,
  )
}

pub type Msg {
  WsWrapper(WebSocketEvent)
  UserEnteredAmount(Side, String)
  UserClickedCurrencySelector(Side)
  UserFilteredCurrencies(Side, String)
  UserPressedKeyInCurrencySelector(Side, NavKey)
  UserSelectedCurrency(Side, Int)
  UserClickedInDocument(browser_event.Event)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WsWrapper(InvalidUrl) -> panic as "invalid url used to open websocket"

    WsWrapper(OnClose(reason)) -> {
      echo "socket closed. reason: " <> string.inspect(reason)
      // todo as "connection closed. open again? show msg?"
      #(model, effect.none())
    }

    WsWrapper(OnOpen(socket)) -> {
      let effect =
        model
        |> build_rate_request
        |> subscribe_to_rate_updates(socket, _)

      #(Model(..model, socket: Some(socket)), effect)
    }

    WsWrapper(OnTextMessage(msg)) -> {
      case json.parse(msg, rate_response.decoder()) {
        Error(_) -> {
          echo "failed to decode conversion response from server: " <> msg
          #(model, effect.none())
        }

        Ok(RateResponse(from, to, rate, _source)) -> {
          let assert Ok(_from_currency) =
            model.currencies
            |> list.find(fn(currency) { currency.id == from })

          let assert Ok(_to_currency) =
            model.currencies
            |> list.find(fn(currency) { currency.id == to })

          let assert Ok(rate) = positive_float.new(rate)
          let model = model_with_rate(model, rate)

          #(model, effect.none())
        }
      }
    }

    UserEnteredAmount(side, amount_str) -> #(
      model_with_amount(model, side, amount_str),
      effect.none(),
    )

    UserClickedCurrencySelector(side) -> {
      let model =
        model
        |> model_with_currency_filter(side, "", currency_matches_filter)
        |> model_with_focused_index(side, fn() { None })
        |> toggle_currency_selector_dropdown(side)

      let effect = {
        let dropdown_visible =
          model
          |> map_conversion_input(side, fn(input) {
            input.currency_selector.show_dropdown
          })

        case dropdown_visible {
          False -> effect.none()
          True ->
            // apply focus to filter input when opening dropdown
            effect.before_paint(fn(_, _) {
              let currency_selector_id =
                model
                |> map_conversion_input(side, fn(input) {
                  input.currency_selector.id
                })

              let assert Ok(filter_elem) =
                document.query_selector("#" <> currency_selector_id <> " input")

              browser_element.focus(filter_elem)
            })
        }
      }

      #(model, effect)
    }

    UserFilteredCurrencies(side, filter_str) -> #(
      model_with_currency_filter(
        model,
        side,
        filter_str,
        currency_matches_filter,
      ),
      effect.none(),
    )

    UserPressedKeyInCurrencySelector(side, key) -> {
      case key {
        ArrowDown -> navigate_currency_selector(model, side, key)
        ArrowUp -> navigate_currency_selector(model, side, key)
        Enter -> select_currency_via_enter_key(model, side)
        Other(_) -> #(model, effect.none())
      }
    }

    UserSelectedCurrency(side, currency_id) -> {
      let assert Ok(currency) =
        model.currencies
        |> list.find(fn(c) { c.id == currency_id })

      let model =
        model
        |> model_with_selected_currency(side, currency)
        |> toggle_currency_selector_dropdown(side)

      let effect = try_subscribe_to_rate_updates(model)

      #(model, effect)
    }

    UserClickedInDocument(event) -> {
      let assert Ok(clicked_elem) =
        event
        |> browser_event.target
        |> browser_element.cast

      let close_dropdown = fn(model, side) {
        let #(currency_selector_id, dropdown_visible) =
          model
          |> map_conversion_input(side, fn(conversion_input) {
            #(
              conversion_input.currency_selector.id,
              conversion_input.currency_selector.show_dropdown,
            )
          })

        let assert Ok(currency_selector_elem) =
          document.get_element_by_id(currency_selector_id)

        let clicked_outside_dropdown =
          !browser_element.contains(currency_selector_elem, clicked_elem)

        let should_toggle = dropdown_visible && clicked_outside_dropdown
        case should_toggle {
          False -> model
          True ->
            model
            |> toggle_currency_selector_dropdown(side)
        }
      }

      let model =
        model
        |> close_dropdown(Left)
        |> close_dropdown(Right)

      #(model, effect.none())
    }
  }
}

fn try_subscribe_to_rate_updates(model: Model) -> Effect(Msg) {
  case model.socket {
    None -> {
      echo "could not request rate. socket not initialized."
      effect.none()
    }

    Some(socket) ->
      model
      |> build_rate_request
      |> subscribe_to_rate_updates(socket, _)
  }
}

fn subscribe_to_rate_updates(
  socket: WebSocket,
  rate_request: RateRequest,
) -> Effect(Msg) {
  rate_request
  |> rate_request.encode
  |> json.to_string
  |> socket.send(socket, _)
}

fn build_rate_request(model: Model) -> RateRequest {
  let #(left_input, right_input) = model.conversion.conversion_inputs
  RateRequest(
    left_input.currency_selector.selected_currency.id,
    right_input.currency_selector.selected_currency.id,
  )
}

pub fn view(model: Model) -> Element(Msg) {
  element.fragment([header(), main_content(model)])
}

fn header() -> Element(Msg) {
  html.div([attribute.class("navbar border-b")], [
    html.div([attribute.class("flex-1 pl-4")], [
      html.h1([attribute.class("w-full mx-auto max-w-screen-xl text-4xl")], [
        html.text("rates"),
      ]),
    ]),
    html.div([attribute.class("flex-none")], [theme_controller()]),
  ])
}

fn theme_controller() {
  let sun_icon =
    svg.svg(
      [
        attribute.attribute("stroke-linejoin", "round"),
        attribute.attribute("stroke-linecap", "round"),
        attribute.attribute("stroke-width", "2"),
        attribute.attribute("stroke", "currentColor"),
        attribute.attribute("fill", "none"),
        attribute.attribute("viewBox", "0 0 24 24"),
        attribute.attribute("height", "20"),
        attribute.attribute("width", "20"),
        attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
      ],
      [
        svg.circle([
          attribute.attribute("r", "5"),
          attribute.attribute("cy", "12"),
          attribute.attribute("cx", "12"),
        ]),
        svg.path([
          attribute.attribute(
            "d",
            "M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4",
          ),
        ]),
      ],
    )
  let moon_icon =
    svg.svg(
      [
        attribute.attribute("stroke-linejoin", "round"),
        attribute.attribute("stroke-linecap", "round"),
        attribute.attribute("stroke-width", "2"),
        attribute.attribute("stroke", "currentColor"),
        attribute.attribute("fill", "none"),
        attribute.attribute("viewBox", "0 0 24 24"),
        attribute.attribute("height", "20"),
        attribute.attribute("width", "20"),
        attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
      ],
      [
        svg.path([
          attribute.attribute(
            "d",
            "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z",
          ),
        ]),
      ],
    )

  html.label([attribute.class("flex cursor-pointer gap-2")], [
    moon_icon,
    html.input([
      attribute.type_("checkbox"),
      attribute.class("toggle theme-controller"),
      attribute.value("lofi"),
    ]),
    sun_icon,
  ])
}

fn main_content(model: Model) -> Element(Msg) {
  let equal_sign =
    html.p([attribute.class("text-3xl font-semi-bold")], [element.text("=")])

  let conversion_input_elem = fn(side) {
    let target_conversion_input = case side {
      Left -> model.conversion.conversion_inputs.0
      Right -> model.conversion.conversion_inputs.1
    }

    let on_currency_selected = fn(currency_id_str) {
      let assert Ok(currency_id) = int.parse(currency_id_str)
      UserSelectedCurrency(side, currency_id)
    }

    let on_keydown_in_dropdown = fn(key_str) {
      let nav_key = case key_str {
        "ArrowUp" -> ArrowUp
        "ArrowDown" -> ArrowDown
        "Enter" -> Enter
        s -> Other(s)
      }

      UserPressedKeyInCurrencySelector(side, nav_key)
    }

    conversion_input(
      amount_input(
        "amount-input-" <> side.to_string(side),
        target_conversion_input.amount_input,
        UserEnteredAmount(side, _),
      ),
      currency_selector(
        target_conversion_input.currency_selector,
        UserClickedCurrencySelector(side),
        UserFilteredCurrencies(side, _),
        on_keydown_in_dropdown,
        on_currency_selected,
      ),
    )
  }

  html.div(
    [
      attribute.class(
        "flex flex-col md:flex-row "
        <> "items-center justify-center p-4 "
        <> "space-y-4 md:space-y-0 md:space-x-4",
      ),
    ],
    [conversion_input_elem(Left), equal_sign, conversion_input_elem(Right)],
  )
}

fn conversion_input(
  amount_input: Element(Msg),
  currency_selector: Element(Msg),
) -> Element(Msg) {
  html.span([attribute.class("flex flex-row items-center space-x-2")], [
    amount_input,
    currency_selector,
  ])
}

fn amount_input(
  id: String,
  amount_input: AmountInput,
  on_change: fn(String) -> Msg,
) -> Element(Msg) {
  auto_resize_input.element([
    auto_resize_input.id(id),
    auto_resize_input.value(amount_input.raw),
    auto_resize_input.min_width(4),
    on_change
      |> auto_resize_input.on_change
      |> event.debounce(300),
  ])
}

fn currency_selector(
  currency_selector: CurrencySelector,
  on_btn_click: Msg,
  on_filter: fn(String) -> Msg,
  on_keydown_in_dropdown: fn(String) -> Msg,
  on_select: fn(String) -> Msg,
) -> Element(Msg) {
  let dropdown_options =
    currency_selector.currencies
    |> currency_collection.index_map(
      currency_collection.currency_type_to_string,
      fn(currency, index) {
        DropdownOption(
          value: int.to_string(currency.id),
          display: html.text(currency.symbol <> " - " <> currency.name),
          is_focused: Some(index) == currency_selector.focused_index,
        )
      },
    )

  button_dropdown.view(
    currency_selector.id,
    currency_selector.selected_currency.symbol,
    currency_selector.show_dropdown,
    currency_selector.currency_filter,
    dropdown_options,
    on_btn_click,
    on_filter,
    on_keydown_in_dropdown,
    on_select,
  )
}
