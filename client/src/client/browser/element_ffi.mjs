import { Ok, Error } from "../../gleam.mjs";

export function cast(raw) {
  if (raw instanceof Element) {
    return new Ok(raw);
  }
  return new Error();
}

export function contains(elem1, elem2) {
  return elem1.contains(elem2);
}

export function nextElementSibling(elem) {
  let sibling = elem.nextElementSibling;
  return sibling ? new Ok(sibling) : new Error();
}

export function innerText(element) {
  return element.innerText;
}

export function getComputedStyleProperty(elem, propertyName) {
  const styles = window.getComputedStyle(elem);
  return styles[propertyName];
}

export function copyInputStyles(from_elem, to_elem) {
  const styles = window.getComputedStyle(from_elem);
  to_elem.style.fontFamily = styles.fontFamily;
  to_elem.style.fontSize = styles.fontSize;
  to_elem.style.fontWeight = styles.fontWeight;
  to_elem.style.letterSpacing = styles.letterSpacing;
  to_elem.style.lineHeight = styles.lineHeight;
}

export function offsetWidth(elem) {
  return elem.offsetWidth;
}

export function focus(elem) {
  elem.focus();
}

export function scrollIntoView(element) {
  element.scrollIntoView({ behavior: "instant", block: "center" });
}
