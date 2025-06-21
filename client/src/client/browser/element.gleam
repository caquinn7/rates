import gleam/dynamic.{type Dynamic}

pub type Element

@external(javascript, "../../element_ffi.mjs", "innerText")
pub fn inner_text(element: Element) -> String

@external(javascript, "../../element_ffi.mjs", "nextElementSibling")
pub fn next_element_sibling(element: Element) -> Result(Element, Nil)

@external(javascript, "../../element_ffi.mjs", "copyInputStyles")
pub fn copy_input_styles(from element1: Element, to element2: Element) -> Nil

@external(javascript, "../../element_ffi.mjs", "offsetWidth")
pub fn offset_width(element: Element) -> Int

@external(javascript, "../../element_ffi.mjs", "getComputedStyleProperty")
pub fn get_computed_style_property(
  element: Element,
  property_name: String,
) -> String

@external(javascript, "../../element_ffi.mjs", "cast")
pub fn cast(element: Dynamic) -> Result(Element, Nil)

/// Returns `True` if:
/// 
/// * the second element is a descendant of the first
/// 
/// or
/// 
/// * the second element is the same element as the first
/// 
/// Otherwise `False`.
@external(javascript, "../../element_ffi.mjs", "contains")
pub fn contains(element1: Element, element2: Element) -> Bool
