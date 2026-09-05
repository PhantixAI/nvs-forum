# frozen_string_literal: true

describe DiscourseEvents::CalendarSeparation do
  fab!(:user)

  describe ".enabled?" do
    it "is false when no UserField named 'College' exists" do
      expect(described_class.enabled?).to eq(false)
    end

    it "is true when a UserField named 'College' exists" do
      Fabricate(:user_field, name: "College")

      expect(described_class.enabled?).to eq(true)
    end
  end

  describe ".value_for_user" do
    it "is nil when the feature is disabled" do
      expect(described_class.value_for_user(user)).to be_nil
    end

    it "is nil for a nil user" do
      Fabricate(:user_field, name: "College")

      expect(described_class.value_for_user(nil)).to be_nil
    end

    it "returns the user's own answer for the configured field when enabled" do
      field = Fabricate(:user_field, name: "College")
      user.custom_fields["user_field_#{field.id}"] = "MIT"
      user.save_custom_fields

      expect(described_class.value_for_user(user)).to eq("MIT")
    end
  end
end
