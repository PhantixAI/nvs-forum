# frozen_string_literal: true

RSpec.describe DirectoryItemSerializer do
  fab!(:user)
  fab!(:directory_column) do
    DirectoryColumn.create!(name: "topics_entered", enabled: true, position: 1)
  end
  fab!(:user_field_1) { Fabricate(:user_field, name: "user_field_1", searchable: true) }
  fab!(:user_field_2) { Fabricate(:user_field, name: "user_field_2", searchable: false) }

  before { DirectoryItem.refresh! }

  context "when serializing user fields" do
    it "serializes user fields with searchable and non-searchable values" do
      user.user_custom_fields.create!(name: "user_field_1", value: "Value 1")
      user.user_custom_fields.create!(name: "user_field_2", value: "Value 2")

      user_fields =
        serialized_payload(
          attributes: DirectoryColumn.active_column_names,
          user_custom_field_map: {
            "user_field_1" => user_field_1.id,
            "user_field_2" => user_field_2.id,
          },
          searchable_fields: [user_field_1],
        )

      expect(user_fields).to eq(
        user_field_1.id => {
          value: ["Value 1"],
          searchable: true,
        },
        user_field_2.id => {
          value: ["Value 2"],
          searchable: false,
        },
      )
    end

    it "handles multiple values for the same field" do
      user.user_custom_fields.create!(name: "user_field_1", value: "Value 1")
      user.user_custom_fields.create!(name: "user_field_1", value: "Another Value")

      user_fields =
        serialized_payload(
          attributes: DirectoryColumn.active_column_names,
          user_custom_field_map: {
            "user_field_1" => user_field_1.id,
          },
          searchable_fields: [],
        )

      expect(user_fields[user_field_1.id]).to eq(
        value: ["Value 1", "Another Value"],
        searchable: false,
      )
    end
  end

  context "when serializing is_batch_moderator" do
    fab!(:college_field) { Fabricate(:user_field, name: "College", requirement: "optional") }
    fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
    fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }

    def sync(user, branch:, batch:)
      user.custom_fields["#{User::USER_FIELD_PREFIX}#{college_field.id}"] = "MNIT Jaipur"
      user.custom_fields["#{User::USER_FIELD_PREFIX}#{branch_field.id}"] = branch
      user.custom_fields["#{User::USER_FIELD_PREFIX}#{batch_field.id}"] = batch
      user.save_custom_fields(true, run_validations: false)
      BatchModeration::GroupSync.sync(user)
    end

    # The controller precomputes batch-moderator status for a whole page of
    # users in one pass (see `DirectoryItemsController#index`) and hands it to
    # the serializer as `batch_moderator_user_ids`, rather than the serializer
    # querying per row, so these tests build that same precomputed set.
    def batch_moderator_user_ids
      BatchModeration::GroupSync.batch_moderator_user_ids(User.pluck(:id))
    end

    it "is true when the site setting is enabled and the user owns a batch group" do
      SiteSetting.enable_batch_moderation = true
      sync(user, branch: "CSE", batch: "2024")
      Group.last.add_owner(user)

      payload =
        serialized_payload(
          { attributes: [], batch_moderator_user_ids: batch_moderator_user_ids },
          :is_batch_moderator,
        )
      expect(payload).to eq(true)
    end

    it "is false when the user is a batch group member but not an owner" do
      SiteSetting.enable_batch_moderation = true
      SiteSetting.batch_moderation_auto_promote_count = 0
      other_user = Fabricate(:user)
      sync(other_user, branch: "CSE", batch: "2024")
      sync(user, branch: "CSE", batch: "2024")

      payload =
        serialized_payload(
          { attributes: [], batch_moderator_user_ids: batch_moderator_user_ids },
          :is_batch_moderator,
        )
      expect(payload).to eq(false)
    end

    it "is false when the site setting is disabled even if the user owns a batch group" do
      SiteSetting.enable_batch_moderation = true
      sync(user, branch: "CSE", batch: "2024")
      Group.last.add_owner(user)
      ids = batch_moderator_user_ids
      SiteSetting.enable_batch_moderation = false

      # Mirrors the controller, which skips computing `batch_moderator_user_ids`
      # entirely when the setting is off, so the serializer never sees it.
      payload = serialized_payload({ attributes: [] }, :is_batch_moderator)
      expect(ids).to include(user.id)
      expect(payload).to eq(false)
    end
  end

  context "when serializing directory columns" do
    let :serializer do
      directory_item =
        DirectoryItem.find_by(user: user, period_type: DirectoryItem.period_types[:all])
      DirectoryItemSerializer.new(
        directory_item,
        { attributes: DirectoryColumn.active_column_names },
      )
    end

    it "serializes attributes for enabled directory_columns" do
      DirectoryColumn.update_all(enabled: true)

      payload = serializer.as_json
      expect(payload[:directory_item].keys).to include(*DirectoryColumn.pluck(:name).map(&:to_sym))
    end

    it "doesn't serialize attributes for disabled directory columns" do
      DirectoryColumn.update_all(enabled: false)
      directory_column = DirectoryColumn.first
      directory_column.update(enabled: true)

      payload = serializer.as_json
      expect(payload[:directory_item].keys.count).to eq(4)
      expect(payload[:directory_item]).to have_key(directory_column.name.to_sym)
      expect(payload[:directory_item]).to have_key(:id)
      expect(payload[:directory_item]).to have_key(:user)
      expect(payload[:directory_item]).to have_key(:time_read)
    end
  end

  private

  def serialized_payload(serializer_opts, key = :user_fields)
    serializer =
      DirectoryItemSerializer.new(
        DirectoryItem.find_by(user: user),
        serializer_opts.merge(scope: Guardian.new(user)),
      )
    serializer.as_json.dig(:directory_item, :user, key)
  end
end
