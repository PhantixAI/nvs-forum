// Shared between post-event-builder.gjs (the Advanced settings modal) and
// compact-event-editor.gjs (the inline editor shown directly under the composer,
// e.g. right after clicking "Create event") so the two surfaces never drift on
// when the Event visibility control shows, or which options it offers.
export const EVENT_SCOPES = ["batch", "college", "forum"];

// Hides the control entirely on a site with no configured institution field at all --
// there's no college-based scoping happening on such a site to begin with.
export function showEventScope(site) {
  return !!site.calendar_event_scope_fields?.institution;
}

// Batch Event needs a configured Batch field to be meaningfully different from College
// Event -- hide the option entirely on a site without one, rather than offer a choice
// that silently collapses to college-level visibility.
export function showBatchEventOption(site) {
  return !!site.calendar_event_scope_fields?.batch;
}
