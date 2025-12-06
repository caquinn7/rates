export function setTimeout(func, delay) {
  return window.setTimeout(func, delay);
}

export function getUrlWithUpdatedQueryParam(key, value) {
  const url = new URL(window.location);
  url.searchParams.set(key, value)
  return url.href;
}