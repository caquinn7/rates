import client/api
import client/browser/document
import client/browser/element as browser_element
import client/browser/event as browser_event
import client/currency/collection as currency_collection
import client/currency/formatting as currency_formatting
import client/positive_float
import client/side.{type Side, Left, Right}
import client/ui/components/auto_resize_input
import client/ui/converter.{type Converter, Converter}
import client/websocket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import gleam/dict
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
import rsvp
import shared/currency.{type Currency}
import shared/page_data.{type PageData}
import shared/rates/rate_response.{RateResponse}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/subscriptions/subscription_response.{SubscriptionResponse}
import shared/websocket_request.{AddCurrencies, Subscribe, Unsubscribe}

pub type Model {
  Model(
    currencies: List(Currency),
    converters: List(Converter),
    socket: Option(WebSocket),
  )
}

pub fn model_from_page_data(page_data: PageData) -> Model {
  let assert [RateResponse(from, to, Some(rate), _source, _timestamp)] =
    page_data.rates

  let assert Ok(from_currency) =
    list.find(page_data.currencies, fn(c) { c.id == from })
    as "invalid currency id in page_data"

  let assert Ok(to_currency) =
    list.find(page_data.currencies, fn(c) { c.id == to })
    as "invalid currency id in page_data"

  let currency_selector = fn(side: Side, selected_currency: Currency) {
    converter.CurrencySelector(
      id: "currency-selector-" <> side.to_string(side),
      show_dropdown: False,
      currency_filter: "",
      currencies: currency_collection.from_list(page_data.currencies),
      selected_currency:,
      focused_index: None,
    )
  }

  let left_input =
    converter.ConverterInput(
      converter.AmountInput("1", Some(positive_float.from_float_unsafe(1.0))),
      currency_selector(Left, from_currency),
    )

  let right_input =
    converter.ConverterInput(
      converter.AmountInput(
        currency_formatting.format_currency_amount(
          to_currency,
          positive_float.from_float_unsafe(rate),
        ),
        Some(positive_float.from_float_unsafe(rate)),
      ),
      currency_selector(Right, to_currency),
    )

  let converter =
    Converter(
      "converter-1",
      [],
      #(left_input, right_input),
      Some(positive_float.from_float_unsafe(rate)),
      Left,
    )
    |> converter.with_master_currency_list(page_data.currencies)

  Model(currencies: page_data.currencies, converters: [converter], socket: None)
}

pub fn model_with_converter(model: Model, converter: Converter) -> Model {
  let converters =
    model.converters
    |> list.map(fn(conv) {
      case conv.id == converter.id {
        True -> converter
        False -> conv
      }
    })

  Model(..model, converters:)
}

pub fn get_next_converter_id(model: Model) -> String {
  let max_id =
    model.converters
    |> list.map(fn(converter) {
      converter.id
      |> string.split_once("-")
      |> result.map(pair.second)
      |> result.try(int.parse)
      |> result.unwrap(0)
    })
    |> list.fold(0, int.max)

  let next_id = max_id + 1

  "converter-" <> int.to_string(next_id)
}

pub fn main() -> Nil {
  let assert Ok(json_str) =
    result.map(document.query_selector("#model"), browser_element.inner_text)
    as "failed to find model element"

  let assert Ok(page_data) = json.parse(json_str, page_data.decoder())
    as "failed to decode page_data"

  let assert Ok(_) = auto_resize_input.register()

  let app = lustre.application(init, update, view)
  let assert Ok(runtime) = lustre.start(app, "#app", page_data)

  document.add_event_listener("click", fn(event) {
    event
    |> UserClickedInDocument
    |> lustre.dispatch
    |> lustre.send(runtime, _)
  })
}

pub fn init(flags: PageData) -> #(Model, Effect(Msg)) {
  #(model_from_page_data(flags), websocket.init("/ws/v2", FromWebSocket))
}

pub type Msg {
  FromWebSocket(WebSocketEvent)
  FromConverter(String, converter.Msg)
  UserClickedAddConverter
  UserClickedInDocument(browser_event.Event)
  ApiReturnedMatchedCurrencies(Result(List(Currency), rsvp.Error))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    FromWebSocket(InvalidUrl) -> panic as "invalid url used to open websocket"

    FromWebSocket(OnClose(reason)) -> {
      echo "socket closed. reason: " <> string.inspect(reason)
      // todo as "connection closed. open again? show msg?"
      #(model, effect.none())
    }

    FromWebSocket(OnOpen(socket)) -> {
      let model = Model(..model, socket: Some(socket))

      let effect =
        model.converters
        |> list.map(subscribe_to_rate_updates(model, _))
        |> effect.batch

      #(model, effect)
    }

    FromWebSocket(OnTextMessage(msg)) -> {
      case json.parse(msg, subscription_response.decoder()) {
        Error(_) -> {
          echo "failed to decode conversion response from server: " <> msg
          #(model, effect.none())
        }

        Ok(SubscriptionResponse(sub_id, rate_response)) -> {
          let RateResponse(from, to, rate, _source, _timestamp) = rate_response

          let assert Ok(target_converter) =
            model.converters
            |> list.find(fn(converter) {
              converter.id == subscription_id.to_string(sub_id)
            })

          let current_request = converter.to_rate_request(target_converter)
          case current_request.from == from && current_request.to == to {
            False -> #(model, effect.none())

            True -> {
              let rate =
                option.map(rate, fn(r) {
                  let assert Ok(r) = positive_float.new(r)
                  r
                })

              let target_converter = converter.with_rate(target_converter, rate)
              #(model_with_converter(model, target_converter), effect.none())
            }
          }
        }
      }
    }

    FromConverter(converter_id, converter_msg) -> {
      let assert Ok(target_converter) =
        model.converters
        |> list.find(fn(converter) { converter.id == converter_id })

      case converter.update(target_converter, converter_msg) {
        #(converter, converter_effect) -> {
          let model = model_with_converter(model, converter)

          let effect = case converter_effect {
            converter.NoEffect -> effect.none()

            converter.FocusOnCurrencyFilter(side) ->
              effect.before_paint(fn(_, _) {
                let currency_selector_id =
                  converter.get_converter_input(converter, side).currency_selector.id

                let assert Ok(filter_elem) =
                  document.query_selector(
                    "#" <> currency_selector_id <> " input",
                  )

                browser_element.focus(filter_elem)
              })

            converter.ScrollToOption(side, index) ->
              effect.before_paint(fn(_, _) {
                let currency_selector_id =
                  converter.get_converter_input(converter, side).currency_selector.id

                let option_elems =
                  document.query_selector_all(
                    "#"
                    <> currency_selector_id
                    <> " .options-container"
                    <> " .dd-option",
                  )

                let assert Ok(target_option_elem) =
                  array.get(option_elems, index)

                browser_element.scroll_into_view(target_option_elem)
              })

            converter.RequestCurrencies(symbol) ->
              api.get_currencies(symbol, ApiReturnedMatchedCurrencies)

            converter.RequestRate -> subscribe_to_rate_updates(model, converter)
          }

          #(model, effect)
        }
      }
    }

    UserClickedAddConverter -> todo

    UserClickedInDocument(event) -> {
      let assert Ok(clicked_elem) =
        event
        |> browser_event.target
        |> browser_element.cast

      let close_dropdown = fn(converter, side) {
        let currency_selector =
          converter.get_converter_input(converter, side).currency_selector

        let currency_selector_id = currency_selector.id
        let dropdown_visible = currency_selector.show_dropdown

        let assert Ok(currency_selector_elem) =
          document.get_element_by_id(currency_selector_id)

        let clicked_outside_dropdown =
          !browser_element.contains(currency_selector_elem, clicked_elem)

        let should_toggle = dropdown_visible && clicked_outside_dropdown
        case should_toggle {
          False -> converter
          True -> converter.with_toggled_dropdown(converter, side)
        }
      }

      let converters =
        model.converters
        |> list.map(fn(converter) {
          converter
          |> close_dropdown(Left)
          |> close_dropdown(Right)
        })

      #(Model(..model, converters:), effect.none())
    }

    ApiReturnedMatchedCurrencies(Error(err)) -> {
      echo "error fetching currencies"
      echo err
      #(model, effect.none())
    }

    ApiReturnedMatchedCurrencies(Ok(matched_currencies)) -> {
      let master_list = {
        let currencies_to_dict = fn(currencies) {
          currencies
          |> list.map(fn(currency: Currency) { #(currency.id, currency) })
          |> dict.from_list
        }

        // Convert both currency lists to dicts indexed by ID, then merge.
        // This deduplicates currencies while giving server data precedence
        // over existing client data for any conflicts.
        model.currencies
        |> currencies_to_dict
        |> dict.merge(currencies_to_dict(matched_currencies))
        |> dict.values
      }

      let converters =
        list.map(model.converters, fn(conv) {
          converter.with_master_currency_list(conv, master_list)
        })

      let model = Model(..model, currencies: master_list, converters:)
      let effect = send_currencies_to_server(model, matched_currencies)

      #(model, effect)
    }
  }
}

fn subscribe_to_rate_updates(model: Model, converter: Converter) -> Effect(Msg) {
  case model.socket {
    None -> {
      echo "could not request rate. socket not initialized."
      effect.none()
    }

    Some(socket) -> {
      let assert Ok(sub_id) = subscription_id.new(converter.id)
        as "invalid subscription id"

      let subscription_req =
        converter
        |> converter.to_rate_request
        |> SubscriptionRequest(sub_id, _)

      [subscription_req]
      |> Subscribe
      |> websocket_request.encode
      |> json.to_string
      |> websocket.send(socket, _)
    }
  }
}

fn send_currencies_to_server(model: Model, currencies_to_add: List(Currency)) {
  case model.socket {
    None -> {
      echo "could not add currencies. socket not initialized."
      effect.none()
    }

    Some(socket) ->
      currencies_to_add
      |> AddCurrencies
      |> websocket_request.encode
      |> json.to_string
      |> websocket.send(socket, _)
  }
}

fn view(model: Model) -> Element(Msg) {
  element.fragment([
    header(),
    main_content(model),
  ])
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
        attribute.class("swap-on h-10 w-10 fill-current"),
        attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
        attribute.attribute("viewbox", "0 0 24 24"),
      ],
      [
        svg.path([
          attribute.attribute(
            "d",
            "M5.64,17l-.71.71a1,1,0,0,0,0,1.41,1,1,0,0,0,1.41,0l.71-.71A1,1,0,0,0,5.64,17ZM5,12a1,1,0,0,0-1-1H3a1,1,0,0,0,0,2H4A1,1,0,0,0,5,12Zm7-7a1,1,0,0,0,1-1V3a1,1,0,0,0-2,0V4A1,1,0,0,0,12,5ZM5.64,7.05a1,1,0,0,0,.7.29,1,1,0,0,0,.71-.29,1,1,0,0,0,0-1.41l-.71-.71A1,1,0,0,0,4.93,6.34Zm12,.29a1,1,0,0,0,.7-.29l.71-.71a1,1,0,1,0-1.41-1.41L17,5.64a1,1,0,0,0,0,1.41A1,1,0,0,0,17.66,7.34ZM21,11H20a1,1,0,0,0,0,2h1a1,1,0,0,0,0-2Zm-9,8a1,1,0,0,0-1,1v1a1,1,0,0,0,2,0V20A1,1,0,0,0,12,19ZM18.36,17A1,1,0,0,0,17,18.36l.71.71a1,1,0,0,0,1.41,0,1,1,0,0,0,0-1.41ZM12,6.5A5.5,5.5,0,1,0,17.5,12,5.51,5.51,0,0,0,12,6.5Zm0,9A3.5,3.5,0,1,1,15.5,12,3.5,3.5,0,0,1,12,15.5Z",
          ),
        ]),
      ],
    )

  let moon_icon =
    svg.svg(
      [
        attribute.class("swap-off h-10 w-10 fill-current"),
        attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
        attribute.attribute("viewbox", "0 0 24 24"),
      ],
      [
        svg.path([
          attribute.attribute(
            "d",
            "M21.64,13a1,1,0,0,0-1.05-.14,8.05,8.05,0,0,1-3.37.73A8.15,8.15,0,0,1,9.08,5.49a8.59,8.59,0,0,1,.25-2A1,1,0,0,0,8,2.36,10.14,10.14,0,1,0,22,14.05,1,1,0,0,0,21.64,13Zm-9.5,6.69A8.14,8.14,0,0,1,7.08,5.22v.27A10.15,10.15,0,0,0,17.22,15.63a9.79,9.79,0,0,0,2.1-.22A8.11,8.11,0,0,1,12.14,19.73Z",
          ),
        ]),
      ],
    )

  html.label([attribute.class("swap swap-rotate")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.class("theme-controller"),
      attribute.value("lofi"),
    ]),
    sun_icon,
    moon_icon,
  ])
}

fn main_content(model: Model) -> Element(Msg) {
  let converter_elems =
    model.converters
    |> list.map(fn(converter_model) {
      converter.view(converter_model)
      |> element.map(FromConverter(converter_model.id, _))
    })

  html.div([attribute.class("container")], [
    html.div([attribute.class("converters")], converter_elems),
  ])
}
