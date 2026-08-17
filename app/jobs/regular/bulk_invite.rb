# frozen_string_literal: true

module Jobs
  class BulkInvite < ::Jobs::Base
    sidekiq_options retry: false

    def initialize
      super

      @logs = []
      @sent = 0
      @skipped = 0
      @skipped_emails = []
      @warnings = 0
      @failed = 0
      @failed_emails = []
      @groups = {}
      @user_fields = {}
      @valid_groups = {}
    end

    def execute(args)
      @invites = args[:invites]
      raise Discourse::InvalidParameters.new(:invites) if @invites.blank?

      @current_user = User.find_by(id: args[:current_user_id])
      raise Discourse::InvalidParameters.new(:current_user_id) unless @current_user

      @skip_email = SiteSetting.skip_email_bulk_invites

      @guardian = Guardian.new(@current_user)

      process_invites(@invites)

      if @invites.length > Invite::BULK_INVITE_EMAIL_LIMIT
        ::Jobs.enqueue(:process_bulk_invite_emails)
      end
    ensure
      notify_user
    end

    private

    def process_invites(invites)
      invites.each do |invite|
        if EmailAddressValidator.valid_value?(invite[:email])
          # email is valid
          result = send_invite(invite)
          if Invite === result
            @sent += 1
          elsif User === result
            @skipped += 1
            @skipped_emails << invite[:email]
          else
            @failed += 1
            @failed_emails << invite[:email]
          end
        else
          # invalid email
          save_log "Invalid Email '#{invite[:email]}"
          @failed += 1
          @failed_emails << invite[:email]
        end
      end
    rescue Exception => e
      save_log "Bulk Invite Process Failed -- '#{e.message}'"
      @failed += 1
      @failed_emails << invite[:email]
    end

    def get_groups(group_names, email)
      groups = []

      if group_names
        group_names = group_names.split(";")

        group_names.each do |group_name|
          group = fetch_group(group_name)

          if group && can_edit_group?(group)
            # valid group
            groups.push(group)
          else
            # invalid group
            save_log "Invalid Group '#{group_name}' for '#{email}'"
            @warnings += 1
          end
        end
      end

      groups
    end

    def get_topic(topic_id, email)
      topic = nil

      if topic_id
        topic = Topic.find_by_id(topic_id)
        if topic.nil?
          save_log "Invalid Topic ID '#{topic_id}' for '#{email}'"
          @warnings += 1
        end
      end

      topic
    end

    def get_user_fields(fields, email)
      user_fields = {}

      fields.each do |key, value|
        @user_fields[key] ||= UserField
          .includes(:user_field_options)
          .where("name ILIKE ?", key)
          .first || :nil
        if @user_fields[key] == :nil
          save_log "Invalid User Field '#{key}' for '#{email}'"
          @warnings += 1
          next
        end

        # Automatically correct user field value
        if @user_fields[key].field_type == "dropdown"
          value =
            @user_fields[key].user_field_options.find { |ufo| ufo.value.casecmp?(value) }&.value
        end

        user_fields[@user_fields[key].id] = value
      end

      user_fields
    end

    def send_invite(invite)
      email = invite[:email]
      groups = get_groups(invite[:groups], email)
      topic = get_topic(invite[:topic_id], email)
      locale = invite[:locale]
      # ActiveModel::Type::Boolean#cast fails open (anything not in its narrow
      # FALSE_VALUES list, e.g. "no"/"n"/a typo, casts to true), which is wrong for a
      # security-relevant flag filled in free-text by an admin -- only treat an explicit
      # truthy spelling as true, everything else (including typos) stays false/bound.
      allow_any_email = %w[true t 1 yes y].include?(invite[:allow_any_email].to_s.strip.downcase)
      user_fields =
        get_user_fields(invite.except(:email, :groups, :topic_id, :locale, :allow_any_email), email)

      begin
        if user = Invite.find_user_by_email(email)
          if groups.present?
            Group.transaction do
              groups.each do |group|
                group.add(user)

                GroupActionLogger.new(@current_user, group).log_add_user_to_group(user)
              end
            end
          end

          if user_fields.present?
            user_fields.each { |user_field, value| user.set_user_field(user_field, value) }
            user.save_custom_fields
          end

          if locale.present?
            user.locale = locale
            user.save!
          end

          user
        else
          # A staged user pre-created here is only ever found and unstaged by
          # create_user_from_invite when the redeemer's email matches the invite's, so for
          # allow_any_email invites (redeemable with any email) it would never be looked up
          # -- silently discarding the prefilled fields/locale and leaving a dangling staged
          # user behind. Warn instead of creating one.
          if allow_any_email && (user_fields.present? || locale.present?)
            save_log "User fields/locale ignored for '#{email}' -- not supported with allow_any_email"
            @warnings += 1
          elsif user_fields.present? || locale.present?
            user = User.where(staged: true).find_by_email(email)
            user ||=
              User.new(username: UserNameSuggester.suggest(email), email: email, staged: true)

            if user_fields.present?
              user_fields.each { |user_field, value| user.set_user_field(user_field, value) }
            end

            user.locale = locale if locale.present?

            user.save!
          end

          # allow_any_email leaves the invite unbound (email: nil), which makes it an
          # "invite link" as far as Invite#is_invite_link? is concerned -- the redeemer
          # can then complete signup with any email address (see InvitesController
          # #perform_accept_invitation and InviteRedeemer#can_redeem_invite?, neither of
          # which enforce an email match for this invite type). `description` keeps the
          # CSV row's email visible on the admin Pending/Redeemed invite list even though
          # it's no longer bound to the invite.
          invite_opts = {
            email: allow_any_email ? nil : email,
            description: allow_any_email ? email : nil,
            topic: topic,
            group_ids: groups.map(&:id),
            skip_email: @skip_email,
          }

          if @invites.length > Invite::BULK_INVITE_EMAIL_LIMIT
            invite_opts[:emailed_status] = Invite.emailed_status_types[:bulk_pending]
          end

          # Invite.generate's own reinvites-per-day limiter only runs when email is
          # present, which allow_any_email rows never satisfy (they pass email: nil by
          # design) -- so without this, repeated allow_any_email rows for the same address
          # would bypass rate limiting entirely, even though this job still knows and
          # delivers to that real address via to_override below. Reuse the exact same
          # limiter key as Invite.generate so bound and unbound invites to the same
          # recipient share one daily budget.
          if allow_any_email
            # Match Invite.generate's own downcasing (Email.downcase) before hashing --
            # otherwise differently-cased rows for the same address (or a subsequent
            # bound invite via Invite.generate) land in different limiter buckets and
            # don't actually share the daily budget this is meant to enforce.
            email_digest = Digest::SHA256.hexdigest(Email.downcase(email))
            RateLimiter.new(
              @current_user,
              "reinvites-per-day-#{email_digest}",
              3,
              1.day.to_i,
            ).performed!
          end

          invite = Invite.generate(@current_user, invite_opts)

          # Invite.generate only auto-sends when email is present, so an unbound invite
          # needs to be delivered explicitly -- to_override tells InviteMailer where to
          # send it without binding the invite to that address. Skip this when the invite
          # is bulk_pending: Jobs::ProcessBulkInviteEmails already re-enqueues delivery for
          # those on its own throttle, and Jobs::InviteEmail falls back to invite.description
          # for the recipient in that case -- enqueuing here too would double-send.
          if allow_any_email && !@skip_email &&
               invite.emailed_status != Invite.emailed_status_types[:bulk_pending]
            # Invite.generate leaves emailed_status at :not_required for an unbound invite
            # (it only auto-assigns :pending when email is present), which would make
            # InvitesController#resend_all_invites treat this as never-emailed and skip it
            # forever. Set it here, via update_column so it doesn't trip Invite.generate's
            # own :pending-triggered auto-enqueue (that has no to_override and would
            # double-send). Jobs::InviteEmail already advances this to :sent once delivered.
            invite.update_column(:emailed_status, Invite.emailed_status_types[:sending])
            ::Jobs.enqueue(:invite_email, invite_id: invite.id, to_override: email)
          end

          invite
        end
      rescue => e
        save_log "Error inviting '#{email}' -- #{Rails::Html::FullSanitizer.new.sanitize(e.message)}"

        nil
      end
    end

    def save_log(message)
      @logs << "[#{Time.now}] #{message}"
    end

    def notify_user
      if @current_user
        if @sent > 0 && @failed == 0
          SystemMessage.create_from_system_user(
            @current_user,
            :bulk_invite_succeeded,
            sent: @sent,
            skipped: @skipped,
            skipped_emails: @skipped_emails.join("\n"),
            warnings: @warnings,
            logs: @logs.join("\n"),
          )
        else
          SystemMessage.create_from_system_user(
            @current_user,
            :bulk_invite_failed,
            sent: @sent,
            skipped: @skipped,
            skipped_emails: @skipped_emails.join("\n"),
            warnings: @warnings,
            failed: @failed,
            failed_emails: @failed_emails.join("\n"),
            logs: @logs.join("\n"),
          )
        end
      end
    end

    def fetch_group(group_name)
      group_name = group_name.downcase
      group = @groups[group_name]

      unless group
        group = Group.find_by("lower(name) = ?", group_name)
        @groups[group_name] = group
      end

      group
    end

    def can_edit_group?(group)
      group_name = group.name.downcase
      result = @valid_groups[group_name]

      unless result
        result = @guardian.can_edit_group?(group)
        @valid_groups[group_name] = result
      end

      result
    end
  end
end
