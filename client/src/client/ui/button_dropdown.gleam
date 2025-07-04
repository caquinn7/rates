import client/ui/button.{Button}
import gleam/dict.{type Dict}
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event

pub type DropdownOption(msg) {
  DropdownOption(value: String, display: Element(msg))
}

pub fn view(
  id: String,
  btn_text: String,
  show_dropdown: Bool,
  filter: String,
  options: Dict(String, List(DropdownOption(msg))),
  on_btn_click: msg,
  on_filter: fn(String) -> msg,
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  html.div([attribute.class("relative"), attribute.id(id)], [
    button.view(Button(btn_text, on_btn_click)),
    dropdown(show_dropdown, filter, options, on_filter, on_option_click),
  ])
}

fn dropdown(
  visible: Bool,
  filter: String,
  options: Dict(String, List(DropdownOption(msg))),
  on_filter: fn(String) -> msg,
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  let filter_elem = currency_filter_input(filter, on_filter)
  let option_group_elems = option_groups(options, on_option_click)

  html.div(
    [
      attribute.class(
        "absolute z-10 border rounded-lg shadow-md max-h-64 overflow-y-auto",
      ),
      attribute.class(
        "min-w-max left-1/2 transform -translate-x-1/2 w-auto translate-y-3",
      ),
      attribute.hidden(!visible),
    ],
    [filter_elem, element.fragment(option_group_elems)],
  )
}

fn currency_filter_input(
  value: String,
  on_input: fn(String) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_("text"),
    attribute.placeholder("Search..."),
    attribute.class("w-full p-2 border-b focus:outline-none"),
    attribute.value(value),
    event.on_input(on_input),
  ])
}

fn option_groups(
  groups: Dict(String, List(DropdownOption(msg))),
  on_option_click: fn(String) -> msg,
) -> List(Element(msg)) {
  groups
  |> dict.to_list
  |> list.map(option_group(_, on_option_click))
}

fn option_group(
  group: #(String, List(DropdownOption(msg))),
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  let #(title, options) = group

  let group_title_div =
    html.div([attribute.class("px-2 py-1 font-bold text-lg")], [
      html.text(title),
    ])

  html.div([], [group_title_div, options_container(options, on_option_click)])
}

fn options_container(
  options: List(DropdownOption(msg)),
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  keyed.div(
    [attribute.class("options-container")],
    list.map(options, fn(opt) {
      let child = option(opt, on_option_click)
      #(opt.value, child)
    }),
  )
}

fn option(
  option: DropdownOption(msg),
  on_click: fn(String) -> msg,
) -> Element(msg) {
  html.div(
    [
      attribute.attribute("data-value", option.value),
      attribute.class("px-6 py-1 cursor-pointer"),
      event.on_click(on_click(option.value)),
    ],
    [option.display],
  )
}
