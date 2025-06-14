import { Ok, Error } from "./gleam.mjs";

export function innerText(element) {
  return element.innerText;
}

export function nextElementSibling(elem) {
  let sibling = elem.nextElementSibling;
  return sibling ? new Ok(sibling) : new Error();
}

export function copyInputStyles(from_elem, to_elem) {
  const styles = window.getComputedStyle(from_elem);
  to_elem.style.fontFamily = styles.fontFamily;
  to_elem.style.fontSize = styles.fontSize;
  to_elem.style.fontWeight = styles.fontWeight;
  to_elem.style.letterSpacing = styles.letterSpacing;
  to_elem.style.lineHeight = styles.lineHeight;
}

export function getComputedStyleProperty(elem, propertyName) {
  const styles = window.getComputedStyle(elem);
  return styles[propertyName];
}

export function offsetWidth(elem) {
  return elem.offsetWidth;
}
