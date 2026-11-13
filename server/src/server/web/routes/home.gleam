import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/currencies/currency_repository.{type CurrencyRepository}
import shared/client_state.{type ClientState, type ConverterState, ClientState}
import shared/currency.{type Currency}
import shared/page_data.{type PageData, PageData}
import wisp.{type Response}

pub fn get(
  currency_repository: CurrencyRepository,
  client_state: Option(ClientState),
) -> Response {
  resolve_page_data(currency_repository, client_state)
  |> page_data.encode
  |> json.to_string
  |> page_scaffold
  |> element.to_document_string
  |> wisp.html_body(wisp.response(200), _)
}

pub fn resolve_page_data(
  currency_repository: CurrencyRepository,
  client_state: Option(ClientState),
) -> PageData {
  let client_state = case client_state {
    Some(state) -> state
    None -> ClientState([client_state.default_converter])
  }

  let currencies = currency_repository.get_all()
  let converters = {
    let validated = filter_valid_converters(client_state.converters, currencies)
    case validated {
      [] -> [client_state.default_converter]
      _ -> validated
    }
  }
  PageData(currencies:, converters:)
}

fn filter_valid_converters(
  converters: List(ConverterState),
  currencies: List(Currency),
) {
  let currency_exists = fn(id) {
    list.any(currencies, fn(currency) { currency.id == id })
  }

  list.filter(converters, fn(converter) {
    currency_exists(converter.from) && currency_exists(converter.to)
  })
}

fn page_scaffold(seed_json: String) -> Element(a) {
  // Escape '<' for the HTML script context; JSON decoding restores it.
  let seed_json = string.replace(seed_json, "<", "\\u003c")

  html.html(
    [
      attribute.attribute("lang", "en"),
      attribute.attribute("data-theme", "dracula"),
    ],
    [
      html.head([], [
        html.meta([attribute.attribute("charset", "UTF-8")]),
        html.meta([
          attribute.attribute(
            "content",
            "width=device-width, initial-scale=1.0",
          ),
          attribute.name("viewport"),
        ]),
        html.title([], "rates 💹"),
        html.link([
          attribute.rel("stylesheet"),
          attribute.type_("text/css"),
          attribute.href("/static/client.css"),
        ]),
        html.script(
          [attribute.src("/static/client.js"), attribute.type_("module")],
          "",
        ),
        html.script(
          [attribute.type_("application/json"), attribute.id("model")],
          seed_json,
        ),
      ]),
      html.body([attribute.class("flex flex-col min-h-screen")], [
        html.div([attribute.id("app")], []),
      ]),
    ],
  )
}
