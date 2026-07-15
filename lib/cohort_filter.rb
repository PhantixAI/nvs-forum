# frozen_string_literal: true

# Shared cohort-filter query logic, used by both the public users directory
# (`DirectoryItemsQuery`) and the admin users list (`AdminUserIndexQuery`).
# Filters a `users`-rooted (or `users`-joined) relation by the same
# College/Vidyalaya/Batch/Branch UserFields the batch-moderation cohort
# groups are keyed on.
module CohortFilter
  # Derived from the same admin-configurable site settings
  # BatchModeration::GroupSync itself resolves cohort fields through
  # (institution/batch/secondary field names), rather than a fixed list --
  # a hardcoded list here would silently stop matching anything the moment
  # an admin reconfigures those settings to different UserField names, even
  # though GroupSync would keep working correctly with the new names.
  def self.field_names
    (
      SiteSetting.batch_moderation_institution_field_names.split("|") +
        [SiteSetting.batch_moderation_batch_field_name] +
        SiteSetting.batch_moderation_secondary_field_names.split("|")
    ).reject(&:blank?).uniq
  end

  # `filters_json` is a JSON object of `{ user_field_id => value }`,
  # e.g. `{"1":"NIT Trichy","3":"2024"}`, built by the cohort filter
  # dropdowns (College/Branch/Batch/Vidyalaya). `id_column` names the column
  # to join `user_custom_fields.user_id` against -- `"users.id"` works
  # unchanged whether `items` is rooted directly on `User` or joined to it
  # through an association (as long as the caller has already called
  # `.references(:user)` in the latter case).
  def self.apply(items, filters_json, guardian:, id_column: "users.id")
    return items if filters_json.blank?

    filter_values =
      begin
        JSON.parse(filters_json)
      rescue JSON::ParserError
        {}
      end
    return items unless filter_values.is_a?(Hash)
    return items if filter_values.blank?

    allowed_field_scope = guardian&.is_staff? ? UserField.all : UserField.public_fields
    allowed_fields = allowed_field_scope.where(name: field_names).index_by { |f| f.id.to_s }

    filter_values.each do |field_id, value|
      field = allowed_fields[field_id.to_s]
      next if field.blank? || !value.is_a?(String) || value.blank?

      join_sql =
        ActiveRecord::Base.sanitize_sql_array(
          [
            "INNER JOIN user_custom_fields ucf_filter_#{field.id} ON ucf_filter_#{field.id}.user_id = #{id_column} AND ucf_filter_#{field.id}.name = ? AND ucf_filter_#{field.id}.value = ?",
            "#{User::USER_FIELD_PREFIX}#{field.id}",
            value,
          ],
        )
      items = items.joins(join_sql)
    end

    items
  end

  def self.apply_staff_only(items, staff_only, table: "users")
    return items unless staff_only
    items.where("#{table}.admin OR #{table}.moderator")
  end

  # Unlike `apply_staff_only` above (Discourse admin/moderator), "Staff" here
  # is the batch-moderation cohort classification: the member-type UserField
  # (e.g. "I am") holding the site's configured staff label (e.g.
  # "Dean/Professor/Staff" or "Principal/Teacher/Staff").
  def self.institute_staff_only(items, staff_only, table: "users")
    return items unless staff_only
    items.where("#{table}.id IN (?)", BatchModeration::GroupSync.all_staff_type_user_ids)
  end
end
