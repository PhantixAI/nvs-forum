import { i18n } from "discourse-i18n";

// UserFields eligible as cohort filter dropdowns, in display order.
// `disabledWhenStaffOnly` fields are disabled (and their value cleared) once
// a "Staff Only" toggle is on, since staff don't necessarily belong to a
// Batch/Branch cohort -- they stay visible (just non-interactive) rather
// than disappearing, so the control layout doesn't shift. Only fields that
// actually exist as a UserField on the current site (checked via
// `site.user_fields`, since each site is a separate database with its own
// fields -- see BatchModeration::GroupSync for the same site-detection
// pattern) are rendered. Shared between the public users directory (`/u`)
// and the admin users list.
export const COHORT_FILTER_FIELD_CONFIG = [
  { name: "College", disabledWhenStaffOnly: false },
  { name: "Vidyalaya", disabledWhenStaffOnly: false },
  { name: "Batch", disabledWhenStaffOnly: true },
  { name: "Branch", disabledWhenStaffOnly: true },
];

export function parseCohortFilterValues(filters) {
  if (!filters) {
    return {};
  }

  try {
    const parsed = JSON.parse(filters);
    return typeof parsed === "object" && parsed !== null ? parsed : {};
  } catch {
    return {};
  }
}

export function buildCohortFilterFields({
  siteUserFields,
  filterValues,
  staffOnly,
}) {
  const fields = siteUserFields || [];

  return COHORT_FILTER_FIELD_CONFIG.map((config) => {
    const field = fields.find((f) => f.name === config.name);
    if (!field) {
      return null;
    }

    return {
      id: field.id,
      name: field.name,
      noneLabel: i18n("directory.cohort_filter.all", { name: field.name }),
      value: filterValues[field.id] ?? null,
      disabled: Boolean(staffOnly && config.disabledWhenStaffOnly),
      content: (field.options || []).map((value) => ({
        id: value,
        name: value,
      })),
    };
  }).filter(Boolean);
}

// Returns the updated filter-values map with any `disabledWhenStaffOnly`
// field's value cleared, or `null` if nothing needed clearing. The field
// itself stays visible (just disabled) -- only its selected value is reset,
// so it doesn't silently keep applying to the query while disabled.
export function clearHiddenCohortFilterValues({
  siteUserFields,
  filterValues,
}) {
  const fields = siteUserFields || [];
  const next = { ...filterValues };
  let changed = false;

  COHORT_FILTER_FIELD_CONFIG.filter((c) => c.disabledWhenStaffOnly).forEach(
    (config) => {
      const field = fields.find((f) => f.name === config.name);
      if (field && field.id in next) {
        delete next[field.id];
        changed = true;
      }
    }
  );

  return changed ? next : null;
}
