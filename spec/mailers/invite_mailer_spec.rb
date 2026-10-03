# frozen_string_literal: true

RSpec.describe InviteMailer do
  describe "send_invite" do
    context "when inviting to site" do
      context "with default invite message" do
        fab!(:invite)
        let(:invite_mail) { InviteMailer.send_invite(invite) }

        it "renders the invitee email" do
          expect(invite_mail.to).to eql([invite.email])
        end

        it "renders the subject" do
          expect(invite_mail.subject).to be_present
        end

        it "renders site domain name in subject" do
          expect(invite_mail.subject).to match(Discourse.current_hostname)
        end

        it "renders the body" do
          expect(invite_mail.body).to be_present
        end

        it "renders the inviter email" do
          expect(invite_mail.from).to eql([SiteSetting.notification_email])
        end

        it "renders invite link" do
          expect(invite_mail.body.encoded).to match(
            "#{Discourse.base_url}/invites/#{invite.invite_key}",
          )
        end

        it "omits the email token when invite acceptance uses a code" do
          SiteSetting.enable_local_logins_via_code = true

          expect(invite_mail.body.encoded).to include(
            "#{Discourse.base_url}/invites/#{invite.invite_key}",
          )
          expect(invite_mail.body.encoded).not_to include(invite.email_token)
        end

        %i[enable_local_logins enable_local_logins_via_email].each do |setting|
          it "includes the email token when #{setting} is disabled after enabling codes" do
            SiteSetting.enable_local_logins_via_code = true
            SiteSetting.public_send("#{setting}=", false)

            expect(invite_mail.body.encoded).to include(invite.email_token)
          end
        end

        it "includes the email token when DiscourseConnect is enabled" do
          SiteSetting.enable_local_logins_via_code = true
          SiteSetting.discourse_connect_url = "https://example.com/sso"
          SiteSetting.discourse_connect_secret = "x" * 10
          SiteSetting.enable_discourse_connect = true

          expect(invite_mail.body.encoded).to include(invite.email_token)
        end

        it "includes the email token when invite acceptance uses a password" do
          SiteSetting.enable_local_logins_via_code = false

          expect(invite_mail.body.encoded).to include(invite.email_token)
        end
      end

      context "with custom invite message" do
        fab!(:invite) do
          Fabricate(:invite, custom_message: "Hey, you <b>should</b> join this forum!\n\nWelcome!")
        end

        context "when custom message includes invite link" do
          let(:custom_invite_mail) { InviteMailer.send_invite(invite) }

          it "renders the invitee email" do
            expect(custom_invite_mail.to).to eql([invite.email])
          end

          it "renders the subject" do
            expect(custom_invite_mail.subject).to be_present
          end

          it "renders site domain name in subject" do
            expect(custom_invite_mail.subject).to match(Discourse.current_hostname)
          end

          it "renders the body" do
            expect(custom_invite_mail.body).to be_present
          end

          it "renders custom_message, stripping HTML" do
            expect(custom_invite_mail.body.encoded).to match(
              "Hey, you should join this forum! Welcome!",
            )
          end

          it "renders the inviter email" do
            expect(custom_invite_mail.from).to eql([SiteSetting.notification_email])
          end

          it "renders invite link" do
            expect(custom_invite_mail.body.encoded).to match(
              "#{Discourse.base_url}/invites/#{invite.invite_key}",
            )
          end
        end
      end

      context "with an AI-personalized custom message" do
        fab!(:invite)

        before do
          SiteSetting.bulk_invite_ai_personalization_enabled = true
          # The real pipeline always has the real link somewhere in
          # custom_message (see ResponseValidator, which appends it on its
          # own line after the AI-authored text) -- the mailer itself
          # doesn't care where within custom_message the link sits, just
          # that it's there, so this fixture's exact placement is incidental.
          invite.update!(
            custom_message:
              "A few of us from your college network hang out here, worth a look? #{invite.link}",
            custom_subject: "Quick hello from campus",
          )
        end

        let(:ai_invite_mail) { InviteMailer.send_invite(invite) }

        it "uses custom_subject verbatim as the subject, not a template-derived one" do
          expect(ai_invite_mail.subject).to eq("Quick hello from campus")
        end

        it "renders custom_message as the whole body, with no wrapper sentences" do
          body = ai_invite_mail.body.encoded
          expect(body).to match("A few of us from your college network hang out here")
          expect(body).not_to match("invited you to join")
          expect(body).not_to match("With this note")
        end

        it "still renders the real invite link" do
          expect(ai_invite_mail.body.encoded).to match(
            "#{Discourse.base_url}/invites/#{invite.invite_key}",
          )
        end

        it "falls back to the wrapped custom template when skip_personalization is set on this row" do
          invite.update!(skip_personalization: true)

          mail = InviteMailer.send_invite(invite)

          expect(mail.subject).not_to eq("Quick hello from campus")
          expect(mail.body.encoded).to match("With this note")
          expect(mail.body.encoded).to match("A few of us from your college network hang out here")
        end

        it "falls back to the wrapped custom template when AI personalization is disabled site-wide" do
          SiteSetting.bulk_invite_ai_personalization_enabled = false

          mail = InviteMailer.send_invite(invite)

          expect(mail.subject).not_to eq("Quick hello from campus")
          expect(mail.body.encoded).to match("With this note")
        end

        it "falls back to the wrapped custom template, rather than the subject-less AI one, when custom_subject is blank" do
          # A stale row (custom_message set but custom_subject never
          # populated -- seen in production from before custom_subject
          # existed) must not select ai_personalized_invite_forum_mailer:
          # it has no subject_template of its own and relies entirely on
          # subject_override, which would be blank here, producing a
          # missing-translation subject instead of a real one.
          invite.update!(custom_subject: nil)

          mail = InviteMailer.send_invite(invite)

          expect(mail.subject).not_to include("translation missing")
          expect(mail.subject).not_to eq("Quick hello from campus")
          expect(mail.body.encoded).to match("With this note")
          expect(mail.body.encoded).to match("A few of us from your college network hang out here")
        end
      end

      context "with template modifier" do
        fab!(:invite)
        let(:plugin) { Plugin::Instance.new }
        let(:custom_template) { "plugin_custom_invite_template" }

        before do
          I18n.backend.store_translations(
            :en,
            {
              plugin_custom_invite_template: {
                subject_template: "[%{site_name}] Custom Invite from %{inviter_name}",
                text_body_template:
                  "Custom invite body: %{invite_link}\n\nFrom: %{inviter_name}\nSite: %{site_domain_name}",
              },
            },
          )
        end

        after { I18n.backend.reload! }

        it "allows plugins to customize the invite template" do
          plugin_instance = Plugin::Instance.new
          @modifier_block = Proc.new { |template, passed_invite| custom_template }

          DiscoursePluginRegistry.register_modifier(
            plugin_instance,
            :invite_forum_mailer_template,
            &@modifier_block
          )

          mail = InviteMailer.send_invite(invite)
          expect(mail.subject).to eq(
            I18n.t(
              "#{custom_template}.subject_template",
              site_name: "Discourse",
              inviter_name: "#{invite.invited_by.name} (#{invite.invited_by.username})",
            ),
          )
          DiscoursePluginRegistry.unregister_modifier(
            plugin_instance,
            :invite_forum_mailer_template,
            &@modifier_block
          )
        end
      end
    end

    context "with an explicit recipient override" do
      fab!(:unbound_invite) { Fabricate(:invite, email: nil, max_redemptions_allowed: 10) }
      fab!(:invite)

      it "sends to the override address instead of invite.email" do
        mail = InviteMailer.send_invite(unbound_invite, to: "override@example.com")

        expect(mail.to).to eql(["override@example.com"])
        expect(mail.subject).to be_present
        expect(mail.body).to be_present
      end

      it "falls back to invite.email when no override is given" do
        mail = InviteMailer.send_invite(invite)

        expect(mail.to).to eql([invite.email])
      end

      context "when inviting to a topic" do
        fab!(:trust_level_2)
        let(:topic) do
          Fabricate(
            :topic,
            excerpt: "Topic invite support is now available in Discourse!",
            user: trust_level_2,
          )
        end
        let(:topic_invite) do
          Invite.generate(topic.user, email: nil, topic_id: topic.id, max_redemptions_allowed: 10)
        end

        it "sends to the override address" do
          mail =
            InviteMailer.send_invite(
              topic_invite,
              invite_to_topic: true,
              to: "override@example.com",
            )

          expect(mail.to).to eql(["override@example.com"])
          expect(mail.subject).to match(topic.title)
        end
      end
    end

    context "when inviting to topic" do
      fab!(:trust_level_2)
      let(:topic) do
        Fabricate(
          :topic,
          excerpt: "Topic invite support is now available in Discourse!",
          user: trust_level_2,
        )
      end

      context "with default invite message" do
        let(:invite) do
          topic.invite(topic.user, "name@example.com")
          Invite.find_by(invited_by_id: topic.user.id)
        end

        let(:invite_mail) { InviteMailer.send_invite(invite, invite_to_topic: true) }

        it "renders the invitee email" do
          expect(invite_mail.to).to eql(["name@example.com"])
        end

        it "renders the subject" do
          expect(invite_mail.subject).to be_present
        end

        it "renders topic title in subject" do
          expect(invite_mail.subject).to match(topic.title)
        end

        it "renders site domain name in subject" do
          expect(invite_mail.subject).to match(Discourse.current_hostname)
        end

        it "renders the body" do
          expect(invite_mail.body).to be_present
        end

        it "renders the inviter email" do
          expect(invite_mail.from).to eql([SiteSetting.notification_email])
        end

        it "renders invite link" do
          expect(invite_mail.body.encoded).to match(
            "#{Discourse.base_url}/invites/#{invite.invite_key}",
          )
        end

        it "renders topic title" do
          expect(invite_mail.body.encoded).to match(topic.title)
        end

        it "respects the private_email setting" do
          SiteSetting.private_email = true

          message = invite_mail
          expect(message.body.to_s).not_to include(topic.title)
          expect(message.body.to_s).not_to include(topic.slug)
        end
      end

      context "with custom invite message" do
        let(:invite) do
          topic.invite(
            topic.user,
            "name@example.com",
            nil,
            "Hey, I thought you might enjoy this topic!",
          )

          Invite.find_by(invited_by_id: topic.user.id)
        end
        let(:custom_invite_mail) { InviteMailer.send_invite(invite) }

        it "renders custom_message" do
          expect(custom_invite_mail.body.encoded).to match(
            "Hey, I thought you might enjoy this topic!",
          )
        end

        it "renders invite link" do
          expect(custom_invite_mail.body.encoded).to match(
            "#{Discourse.base_url}/invites/#{invite.invite_key}",
          )
        end
      end
    end
  end
end
