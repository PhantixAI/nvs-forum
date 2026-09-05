# frozen_string_literal: true

describe DiscourseEvents::Events::BasicEventSerializer do
  before do
    SiteSetting.discourse_events_enabled = true
    SiteSetting.discourse_post_event_enabled = true
    SiteSetting.discourse_post_event_allowed_custom_fields = "team"
    Jobs.run_immediately!
  end

  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category:) }
  fab!(:post) { Fabricate(:post, topic:) }
  fab!(:event) { Fabricate(:event, post:) }

  before { event.update!(custom_fields: { "team" => "rocket" }) }

  it "includes custom_fields so they are readable from event listings" do
    json = described_class.new(event, scope: Guardian.new, root: false).as_json
    expect(json[:custom_fields]["team"]).to eq("rocket")
  end

  it "reports forum_event as true when the reserved custom field is absent" do
    json = described_class.new(event, scope: Guardian.new, root: false).as_json
    expect(json[:forum_event]).to eq(true)
  end

  it "reports forum_event as false when the reserved custom field is present" do
    event.update!(custom_fields: { "team" => "rocket", "_calendar_separation_value" => "MIT" })

    json = described_class.new(event, scope: Guardian.new, root: false).as_json
    expect(json[:forum_event]).to eq(false)
  end

  it "returns the topic's category_id" do
    json = described_class.new(event, scope: Guardian.new).as_json
    expect(json[:basic_event][:category_id]).to eq(category.id)
  end

  it "serializes without raising when the associated post is gone" do
    event.stubs(:post).returns(nil)

    json = described_class.new(event, scope: Guardian.new).as_json
    expect(json[:basic_event][:category_id]).to be_nil
    expect(json[:basic_event][:post]).to be_nil
  end
end
