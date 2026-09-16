# frozen_string_literal: true

RSpec.describe EmailLogDetailsSerializer do
  fab!(:admin)

  def serialize(email_log)
    described_class.new(email_log, scope: Guardian.new(admin), root: false).as_json
  end

  it "exposes the headers, subject, and body parsed from raw" do
    email_log = Fabricate(:email_log, raw: <<~EMAIL)
          From: bot@example.com
          To: student@example.com
          Subject: You're invited
          Content-Type: text/plain; charset=UTF-8

          Come join us.
        EMAIL

    serialized = serialize(email_log)

    expect(serialized[:subject]).to eq("You're invited")
    expect(serialized[:body]).to include("Come join us.")
    expect(serialized[:headers]).to include("Subject: You're invited")
  end

  it "falls back to placeholder text when raw is blank" do
    email_log = Fabricate(:email_log, raw: nil)

    serialized = serialize(email_log)

    expect(serialized[:subject]).to eq(I18n.t("emails.incoming.no_subject"))
    expect(serialized[:body]).to eq(I18n.t("emails.incoming.no_body"))
  end
end
