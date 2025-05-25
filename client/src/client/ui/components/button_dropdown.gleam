import client/ui/button
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/function
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event

pub fn register(name: String) -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("id", fn(new_value) {
      Ok(ParentSetId(new_value))
    }),
    component.on_attribute_change("value", fn(new_value) {
      Ok(ParentSetValue(new_value))
    }),
    component.on_property_change("options", {
      let dropdown_option_decoder = {
        use value <- decode.field("value", decode.string)
        use label <- decode.field("label", decode.string)
        decode.success(DropdownOption(value:, label:))
      }

      decode.dict(decode.string, decode.list(dropdown_option_decoder))
      |> decode.map(ParentSetOptions)
    }),
  ])
  |> lustre.register(name)
}

pub fn button_dropdown(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("button-dropdown", attrs, [])
}

pub fn id(id: String) -> Attribute(msg) {
  attribute.id(id)
}

pub fn value(value: String) -> Attribute(msg) {
  attribute.value(value)
}

pub fn options(options: Dict(String, List(DropdownOption))) -> Attribute(msg) {
  let encode_dropdown_option = fn(dropdown_option) {
    let DropdownOption(value, label) = dropdown_option
    json.object([#("value", json.string(value)), #("label", json.string(label))])
  }

  attribute.property(
    "options",
    json.dict(options, function.identity, json.array(_, encode_dropdown_option)),
  )
}

pub type Model {
  Model(
    id: String,
    options: Dict(String, List(DropdownOption)),
    selected: Option(String),
    dropdown_visible: Bool,
  )
}

pub type DropdownOption {
  DropdownOption(value: String, label: String)
}

pub type Msg {
  ParentSetId(String)
  ParentSetValue(String)
  ParentSetOptions(Dict(String, List(DropdownOption)))
  UserClickedButton
  UserSelectedOption(DropdownOption)
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(
    Model(id: "", options: dict.new(), selected: None, dropdown_visible: False),
    effect.none(),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ParentSetId(id) -> #(Model(..model, id:), effect.none())

    ParentSetValue(value) -> #(
      Model(..model, selected: Some(value)),
      effect.none(),
    )

    ParentSetOptions(options) -> #(Model(..model, options:), effect.none())

    UserClickedButton -> #(
      Model(..model, dropdown_visible: !model.dropdown_visible),
      effect.none(),
    )

    UserSelectedOption(dd_option) -> #(
      Model(..model, selected: Some(dd_option.value), dropdown_visible: False),
      event.emit("option-selected", json.string(dd_option.value)),
    )
  }
}

fn view(model: Model) -> Element(Msg) {
  let btn_text = case model.selected {
    None -> "Select one"

    Some(val) -> {
      model.options
      |> dict.values
      |> list.flatten
      |> list.find_map(fn(dd_option) {
        case dd_option.value == val {
          False -> Error(Nil)
          True -> Ok(dd_option.label)
        }
      })
      |> result.unwrap("")
    }
  }

  html.div([attribute.class("relative"), attribute.id(model.id)], [
    button.view(button.Button(btn_text, UserClickedButton)),
    dropdown(model.dropdown_visible, model.options),
  ])
}

fn dropdown(
  visible: Bool,
  dd_options: Dict(String, List(DropdownOption)),
) -> Element(Msg) {
  html.div(
    [
      attribute.class(
        "absolute z-10 border rounded-lg shadow-md max-h-64 overflow-y-auto",
      ),
      attribute.class(
        "min-w-max left-1/2 transform -translate-x-1/2 w-auto translate-y-3",
      ),
      case visible {
        True -> attribute.none()
        False -> attribute.class("hidden")
      },
    ],
    // [search_input(filter), html.div([], [todo])],
    [
      html.div(
        [],
        dd_options
          |> dict.to_list
          |> list.map(option_group),
      ),
    ],
  )
}

// fn search_input(value: String) -> Element(Msg) {
//   html.div([attribute.class("sticky top-0 z-10")], [
//     html.input([
//       attribute.class(
//         "w-full p-2 border-b focus:outline-none bg-neutral text-neutral-content caret-info",
//       ),
//       attribute.placeholder("Search"),
//       attribute.type_("text"),
//       attribute.value(value),
//       event.on_input(UserFilteredOptions),
//     ]),
//   ])
// }

fn option_group(group: #(String, List(DropdownOption))) -> Element(Msg) {
  let group_title_div =
    html.div(
      [attribute.class("px-2 py-1 font-bold text-lg text-base-content")],
      [html.text(group.0)],
    )

  html.div([], [group_title_div, options_container(group.1)])
}

fn options_container(dd_options: List(DropdownOption)) {
  let dd_option = fn(item: DropdownOption) {
    html.div(
      [
        attribute.attribute("data-value", item.value),
        attribute.class("px-6 py-1 cursor-pointer text-base-content"),
        attribute.class("hover:bg-base-content hover:text-base-100"),
        event.on_click(UserSelectedOption(item)),
      ],
      [html.text(item.label)],
    )
  }

  keyed.div(
    [attribute.class("options-container")],
    list.map(dd_options, fn(item) {
      let child = dd_option(item)
      #(item.value, child)
    }),
  )
}
