# frozen_string_literal: true

describe DiscourseEvents::CalendarEventScope do
  fab!(:user)

  describe ".scope_for" do
    it "returns the explicit scope when the new reserved key is present" do
      expect(described_class.scope_for({ "_calendar_event_scope" => "batch" })).to eq("batch")
    end

    it "infers forum when neither the scope key nor a separation value is present (legacy event)" do
      expect(described_class.scope_for({})).to eq("forum")
    end

    it "infers college when a separation value is present but the scope key is absent (legacy event)" do
      expect(described_class.scope_for({ "_calendar_separation_value" => "MIT" })).to eq("college")
    end

    it "ignores an unrecognized explicit scope value and falls back to legacy inference" do
      expect(
        described_class.scope_for(
          { "_calendar_event_scope" => "bogus", "_calendar_separation_value" => "MIT" },
        ),
      ).to eq("college")
    end
  end

  describe ".institution_value_for" do
    it "is nil when no institution field is configured" do
      expect(described_class.institution_value_for(user)).to be_nil
    end

    it "is nil for a nil user even when an institution field is configured" do
      Fabricate(:user_field, name: "College")
      expect(described_class.institution_value_for(nil)).to be_nil
    end

    it "returns the user's own value for the configured institution field" do
      field = Fabricate(:user_field, name: "College")
      user.custom_fields["user_field_#{field.id}"] = "MIT"
      user.save_custom_fields

      expect(described_class.institution_value_for(user)).to eq("MIT")
    end
  end

  describe ".cohort_digest_for" do
    fab!(:college_field) { Fabricate(:user_field, name: "College") }
    fab!(:batch_field) { Fabricate(:user_field, name: "Batch") }

    it "is nil for a nil user" do
      expect(described_class.cohort_digest_for(nil)).to be_nil
    end

    it "is nil when the user's cohort is incomplete (missing batch value)" do
      user.custom_fields["user_field_#{college_field.id}"] = "MIT"
      user.save_custom_fields

      expect(described_class.cohort_digest_for(user)).to be_nil
    end

    it "returns the same digest for two users sharing the same institution+batch cohort" do
      other_user = Fabricate(:user)
      [user, other_user].each do |u|
        u.custom_fields["user_field_#{college_field.id}"] = "MIT"
        u.custom_fields["user_field_#{batch_field.id}"] = "2024"
        u.save_custom_fields
      end

      expect(described_class.cohort_digest_for(user)).to eq(
        described_class.cohort_digest_for(other_user),
      )
    end

    it "returns a different digest for users in a different batch" do
      other_user = Fabricate(:user)
      user.custom_fields["user_field_#{college_field.id}"] = "MIT"
      user.custom_fields["user_field_#{batch_field.id}"] = "2024"
      user.save_custom_fields
      other_user.custom_fields["user_field_#{college_field.id}"] = "MIT"
      other_user.custom_fields["user_field_#{batch_field.id}"] = "2023"
      other_user.save_custom_fields

      expect(described_class.cohort_digest_for(user)).not_to eq(
        described_class.cohort_digest_for(other_user),
      )
    end

    it "is independent of SiteSetting.enable_batch_moderation" do
      SiteSetting.enable_batch_moderation = false
      user.custom_fields["user_field_#{college_field.id}"] = "MIT"
      user.custom_fields["user_field_#{batch_field.id}"] = "2024"
      user.save_custom_fields

      expect(described_class.cohort_digest_for(user)).to be_present
    end

    it "is nil for a staff-type user, since their cohort key is institution-only (no batch/branch distinction)" do
      member_type_field = Fabricate(:user_field, name: "I am")
      user.custom_fields["user_field_#{college_field.id}"] = "MIT"
      user.custom_fields["user_field_#{member_type_field.id}"] = "Dean/Professor/Staff"
      user.save_custom_fields

      expect(described_class.cohort_digest_for(user)).to be_nil
    end
  end

  describe ".visible_to?" do
    fab!(:college_field) { Fabricate(:user_field, name: "College") }
    fab!(:batch_field) { Fabricate(:user_field, name: "Batch") }
    fab!(:event)

    def set_college(u, value)
      u.custom_fields["user_field_#{college_field.id}"] = value
      u.save_custom_fields
    end

    def set_batch(u, value)
      u.custom_fields["user_field_#{batch_field.id}"] = value
      u.save_custom_fields
    end

    it "is always visible for forum scope" do
      event.update!(custom_fields: { "_calendar_event_scope" => "forum" })
      expect(described_class.visible_to?(event, nil)).to eq(true)
    end

    it "matches college scope by the viewer's institution value" do
      set_college(user, "MIT")
      event.update!(
        custom_fields: {
          "_calendar_event_scope" => "college",
          "_calendar_separation_value" => "MIT",
        },
      )

      expect(described_class.visible_to?(event, user)).to eq(true)
    end

    it "rejects college scope for a mismatched institution value" do
      set_college(user, "Stanford")
      event.update!(
        custom_fields: {
          "_calendar_event_scope" => "college",
          "_calendar_separation_value" => "MIT",
        },
      )

      expect(described_class.visible_to?(event, user)).to eq(false)
    end

    it "matches batch scope by the viewer's cohort digest" do
      set_college(user, "MIT")
      set_batch(user, "2024")
      event.update!(
        custom_fields: {
          "_calendar_event_scope" => "batch",
          "_calendar_batch_cohort_digest" => described_class.cohort_digest_for(user),
        },
      )

      expect(described_class.visible_to?(event, user)).to eq(true)
    end

    it "rejects batch scope for a viewer in a different cohort" do
      set_college(user, "MIT")
      set_batch(user, "2023")
      other_digest_owner = Fabricate(:user)
      set_college(other_digest_owner, "MIT")
      set_batch(other_digest_owner, "2024")
      event.update!(
        custom_fields: {
          "_calendar_event_scope" => "batch",
          "_calendar_batch_cohort_digest" => described_class.cohort_digest_for(other_digest_owner),
        },
      )

      expect(described_class.visible_to?(event, user)).to eq(false)
    end
  end
end
