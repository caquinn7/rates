import client/api
import client/browser/document
import client/browser/element as browser_element
import client/browser/event as browser_event
import client/positive_float
import client/side.{Left, Right}
import client/ui/components/auto_resize_input
import client/ui/converter.{type Converter, type NewConverterError}
import client/ui/icons
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
import lustre/element/keyed
import lustre/event
import rsvp
import shared/currency.{type Currency}
import shared/page_data.{type PageData}
import shared/rates/rate_response.{RateResponse}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/subscriptions/subscription_response.{SubscriptionResponse}
import shared/websocket_request.{AddCurrencies, Subscribe, Unsubscribe}

const converter_id_prefix = "converter"

pub type Model {
  Model(
    currencies: List(Currency),
    converters: List(Converter),
    socket: Option(WebSocket),
  )
}

pub fn model_from_page_data(
  page_data: PageData,
) -> Result(Model, NewConverterError) {
  let assert [RateResponse(from, to, Some(rate), _source, _timestamp)] =
    page_data.rates

  use converter <- result.try(converter.new(
    converter_id_prefix <> "-1",
    page_data.currencies,
    #(from, to),
    "1",
    Some(positive_float.from_float_unsafe(rate)),
  ))

  Ok(Model(
    currencies: page_data.currencies,
    converters: [converter],
    socket: None,
  ))
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

  converter_id_prefix <> "-" <> int.to_string(next_id)
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
  let model = case model_from_page_data(flags) {
    Error(err) -> panic as { "error building model: " <> string.inspect(err) }
    Ok(m) -> m
  }

  #(model, websocket.init("/ws", FromWebSocket))
}

pub type Msg {
  FromWebSocket(WebSocketEvent)
  FromConverter(String, converter.Msg)
  UserClickedAddConverter
  UserClickedDeleteConverter(String)
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

          let target_converter = {
            use target_converter <- result.try(
              list.find(model.converters, fn(converter) {
                converter.id == subscription_id.to_string(sub_id)
              }),
            )

            let current_request = converter.to_rate_request(target_converter)
            case current_request.from == from && current_request.to == to {
              False -> Error(Nil)
              True -> Ok(target_converter)
            }
          }

          case target_converter {
            Error(_) -> #(model, effect.none())

            Ok(converter) -> {
              let rate =
                option.map(rate, fn(r) {
                  let assert Ok(r) = positive_float.new(r)
                  r
                })

              let target_converter = converter.with_rate(converter, rate)
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

    UserClickedAddConverter -> {
      let assert Ok(new_converter) =
        converter.new(
          get_next_converter_id(model),
          model.currencies,
          #(1, 2781),
          "1",
          None,
        )

      let model =
        Model(
          ..model,
          converters: list.append(model.converters, [new_converter]),
        )

      let effect = subscribe_to_rate_updates(model, new_converter)

      #(model, effect)
    }

    UserClickedDeleteConverter(converter_id) -> {
      let model =
        Model(
          ..model,
          converters: list.filter(model.converters, fn(converter) {
            converter.id != converter_id
          }),
        )

      let effect = unsubscribe_from_rate_updates(model, converter_id)

      #(model, effect)
    }

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

        case document.get_element_by_id(currency_selector_id) {
          Error(_) -> converter

          Ok(currency_selector_elem) -> {
            let clicked_outside_dropdown =
              !browser_element.contains(currency_selector_elem, clicked_elem)

            let should_toggle = dropdown_visible && clicked_outside_dropdown
            case should_toggle {
              False -> converter
              True -> converter.with_toggled_dropdown(converter, side)
            }
          }
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
      echo "error fetching currencies: " <> string.inspect(err)
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

fn unsubscribe_from_rate_updates(
  model: Model,
  converter_id: String,
) -> Effect(Msg) {
  case model.socket {
    None -> {
      echo "could not unsubscribe from rate update. socket not initialized."
      effect.none()
    }

    Some(socket) -> {
      let assert Ok(sub_id) = subscription_id.new(converter_id)
        as "invalid subscription id"

      sub_id
      |> Unsubscribe
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
  html.label([attribute.class("swap swap-rotate")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.class("theme-controller"),
      attribute.value("lofi"),
    ]),
    icons.sun(),
    icons.moon(),
  ])
}

fn main_content(model: Model) -> Element(Msg) {
  let converter_rows =
    list.index_map(model.converters, fn(converter, index) {
      let is_last_converter = list.length(model.converters) - 1 == index
      let is_only_converter = list.length(model.converters) == 1
      let row = converter_row(converter, is_last_converter, is_only_converter)
      #(converter.id, row)
    })

  html.div([attribute.class("container max-w-4xl mx-auto px-4")], [
    html.div([attribute.class("flex justify-center")], [
      keyed.div(
        [attribute.class("converters flex flex-col mt-4")],
        converter_rows,
      ),
    ]),
  ])
}

fn converter_row(
  converter: Converter,
  show_add: Bool,
  show_delete: Bool,
) -> Element(Msg) {
  let converter_elem =
    converter
    |> converter.view
    |> element.map(FromConverter(converter.id, _))

  let left_column = case show_add {
    False -> html.div([attribute.class("w-12")], [])

    True ->
      html.div([attribute.class("w-12 flex justify-center")], [
        converter_row_button("btn-info", icons.plus(), UserClickedAddConverter),
      ])
  }

  let right_column = case show_delete {
    False ->
      html.div([attribute.class("w-12 flex justify-center")], [
        converter_row_button(
          "btn-warning",
          icons.x(),
          UserClickedDeleteConverter(converter.id),
        ),
      ])

    True -> html.div([attribute.class("w-12")], [])
  }

  html.div(
    [
      attribute.class(
        "grid grid-cols-[3rem_1fr_3rem] items-center gap-4 w-full max-w-fit",
      ),
    ],
    [
      left_column,
      converter_elem,
      right_column,
    ],
  )
}

fn converter_row_button(
  color_class: String,
  icon: Element(Msg),
  on_click: Msg,
) -> Element(Msg) {
  html.button(
    [
      attribute.class(color_class),
      attribute.class("btn btn-circle"),
      event.on_click(on_click),
    ],
    [icon],
  )
}
