import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action, computed } from "@ember/object";
import { dependentKeyCompat } from "@ember/object/compat";
import { service } from "@ember/service";
import EditUserDirectoryColumnsModal from "discourse/components/modal/edit-user-directory-columns";
import EditUserDirectoryColumnsModalReorderable from "discourse/components/modal/edit-user-directory-columns-reorderable";
import {
  buildCohortFilterFields,
  clearHiddenCohortFilterValues,
  parseCohortFilterValues,
} from "discourse/lib/cohort-filter-fields";
import discourseDebounce from "discourse/lib/debounce";
import { longDate } from "discourse/lib/formatter";

/**
 * @typedef {Object} DirectoryParams
 * @property {string} [period]
 * @property {string} [order]
 * @property {boolean | string | null} [asc]
 * @property {string} [name]
 * @property {string | null} [filters]
 * @property {boolean} [staff_only]
 * @property {string | null} [exclude_usernames]
 * @property {string | null} [exclude_groups]
 * @property {string} [user_field_ids]
 * @property {string} [plugin_column_ids]
 */
export default class UsersController extends Controller {
  @service modal;
  @service siteSettings;

  @tracked period = "weekly";

  queryParams = [
    "period",
    "order",
    "asc",
    "name",
    "filters",
    "staff_only",
    "exclude_usernames",
    "exclude_groups",
  ];

  order = "";

  /** @type {boolean | string | null} */
  asc = null;
  name = "";
  filters = null;
  staff_only = false;
  nameInput = null;

  /** @type {string | null} */
  exclude_usernames = null;

  /** @type {string | null} */
  exclude_groups = null;
  isLoading = false;

  /** @type {{ id: number, name: string, type: string, position: number, icon: string | null, user_field_id: number | null }[] | null} */
  columns = null;

  /** @type {DirectoryParams | null} */
  params = null;

  @dependentKeyCompat
  get showTimeRead() {
    return this.period === "all";
  }

  @computed("filters")
  get _cohortFilterValues() {
    return parseCohortFilterValues(this.filters);
  }

  @computed("_cohortFilterValues", "staff_only", "site.user_fields")
  get cohortFilterFields() {
    return buildCohortFilterFields({
      siteUserFields: this.site?.user_fields,
      filterValues: this._cohortFilterValues,
      staffOnly: this.staff_only,
    });
  }

  loadUsers(params = null) {
    if (params) {
      this.set("params", params);
    }

    this.setProperties({
      isLoading: true,
      nameInput: this.params.name,
      order: this.params.order,
    });

    const userFieldIds = this.columns
      .filter((c) => c.type === "user_field")
      .map((c) => c.user_field_id)
      .join("|");
    const pluginColumnIds = this.columns
      .filter((c) => c.type === "plugin")
      .map((c) => c.id)
      .join("|");

    return this.store
      .find(
        "directoryItem",
        Object.assign(this.params, {
          user_field_ids: userFieldIds,
          plugin_column_ids: pluginColumnIds,
        })
      )
      .then((model) => {
        const lastUpdatedAt = model.get("resultSetMeta.last_updated_at");
        this.setProperties({
          model,
          lastUpdatedAt: lastUpdatedAt ? longDate(lastUpdatedAt) : null,
          period: this.params.period,
        });
      })
      .finally(() => {
        this.set("isLoading", false);
      });
  }

  @action
  cohortFilterChanged(fieldId, _, valueAttrs) {
    const next = { ...this._cohortFilterValues };
    if (valueAttrs?.id) {
      next[fieldId] = valueAttrs.id;
    } else {
      delete next[fieldId];
    }

    this.set("filters", Object.keys(next).length ? JSON.stringify(next) : null);
  }

  @action
  toggleStaffOnly() {
    const staffOnly = !this.staff_only;
    const updates = { staff_only: staffOnly };

    if (staffOnly) {
      const next = clearHiddenCohortFilterValues({
        siteUserFields: this.site?.user_fields,
        filterValues: this._cohortFilterValues,
      });

      if (next) {
        updates.filters = Object.keys(next).length
          ? JSON.stringify(next)
          : null;
      }
    }

    this.setProperties(updates);
  }

  @action
  showEditColumnsModal() {
    // TODO (ui-kit-reorderable-list-cleanup) drop the branch and the legacy
    // component once the change ships.
    const Modal = this.siteSettings.enable_new_reordering_controls
      ? EditUserDirectoryColumnsModalReorderable
      : EditUserDirectoryColumnsModal;

    this.modal.show(Modal);
  }

  @action
  onUsernameFilterChanged(filter) {
    discourseDebounce(this, this._setUsernameFilter, filter, 500);
  }

  @action
  updateOrderAndAsc(order, asc) {
    this.setProperties({ order, asc });
  }

  @action
  loadMore() {
    this.model.loadMore();
  }

  _setUsernameFilter(username) {
    this.setProperties({
      name: username,
      "params.name": username,
    });
    this.loadUsers();
  }
}
