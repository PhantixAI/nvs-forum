import { isProduction } from "discourse/lib/environment";
import loadSentryBrowser from "discourse/lib/load-sentry-browser";

const SENTRY_DSN =
  "https://ccf912bb2adf15b79d1f2241de857f4a@o4511980973916160.ingest.us.sentry.io/4511984205561856";

const ROUTE_TRANSITION_START_MARK = "route-transition-start";
const ROUTE_TRANSITION_END_MARK = "route-transition-end";
const ROUTE_TRANSITION_MEASURE = "route-transition";

let Sentry;
let router;

function handleRouteWillChange(transition) {
  // Ignore intermediate transitions (e.g. loading substates), matching the
  // existing page-tracking instance-initializer's convention.
  if (transition.isIntermediate) {
    return;
  }
  performance.mark(ROUTE_TRANSITION_START_MARK);
}

function handleRouteDidChange(transition) {
  if (transition.isAborted) {
    return;
  }
  try {
    performance.mark(ROUTE_TRANSITION_END_MARK);
    const measure = performance.measure(
      ROUTE_TRANSITION_MEASURE,
      ROUTE_TRANSITION_START_MARK,
      ROUTE_TRANSITION_END_MARK
    );
    Sentry?.captureMessage("route_transition", {
      level: "info",
      extra: { durationMs: measure.duration, route: transition.to?.name },
    });
  } catch {
    // No matching route-transition-start mark (e.g. initial boot transition) — nothing to report.
  }
}

// The app already records a "discourse-init-to-paint" measure (see
// ApplicationController#trackDiscoursePainted) but never reports it
// anywhere — this is the cheapest way to get that existing data into
// Sentry without duplicating the marks it depends on.
function reportInitToPaint() {
  setTimeout(() => {
    const [measure] = performance.getEntriesByName("discourse-init-to-paint");
    if (measure) {
      Sentry?.captureMessage("discourse_init_to_paint", {
        level: "info",
        extra: { durationMs: measure.duration },
      });
    }
  }, 5000);
}

export default {
  after: "inject-objects",

  async initialize(owner) {
    if (!isProduction() || !SENTRY_DSN) {
      return;
    }

    Sentry = await loadSentryBrowser();
    Sentry.init({
      dsn: SENTRY_DSN,
      environment: "production",
      tracesSampleRate: 0.1,
      initialScope: { tags: { surface: "web" } },
    });

    // eslint-disable-next-line ember/no-private-routing-service
    router = owner.lookup("router:main");
    router.on("routeWillChange", handleRouteWillChange);
    router.on("routeDidChange", handleRouteDidChange);

    reportInitToPaint();
  },

  teardown() {
    router?.off("routeWillChange", handleRouteWillChange);
    router?.off("routeDidChange", handleRouteDidChange);
  },
};
