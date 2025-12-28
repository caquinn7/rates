export function replaceState(state, url) {
  if (url?.trim()) {
    history.replaceState(state, '', url);
  } else {
    history.replaceState(state, '');
  }
}