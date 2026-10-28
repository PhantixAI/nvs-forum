# frozen_string_literal: true

class Invite < ActiveRecord::Base
  class UserExists < StandardError
  end

  class RedemptionFailed < StandardError
  end

  class ValidationFailed < StandardError
  end

  include RateLimiter::OnCreateRecord
  include Trashable

  # Only governs the immediate-vs-throttled threshold for unbound
  # (allow_any_email) bulk-invite rows -- see Jobs::BulkInvite#send_invite.
  # Bound bulk invites always throttle through :bulk_pending regardless of
  # CSV size (Jobs::ProcessBulkInviteEmails paces them one at a time).
  BULK_INVITE_EMAIL_LIMIT = 200
  DOMAIN_REGEX =
    /\A(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)+([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])\z/
  # Selecting this in the domain filter is an umbrella match (see
  # domain_filter_condition) covering every *.ac.in institute domain in one
  # view, not just a literal "ac.in" address.
  AC_IN_UMBRELLA_DOMAIN = "ac.in"
  # Every value Invite#delivery_status can return, in pipeline order -- except
  # nil (for not_required), which isn't a filterable status. "review" only
  # ever matches on the Pending tab (see .pending/.with_delivery_status) --
  # Expired has no meaningful "review" state, so the frontend hides that
  # option there; selecting it anyway just returns no rows. Covers both the
  # :review and :drafting emailed_status values -- the latter is deliberately
  # not its own filterable status, since it's a transient (seconds-to-low-
  # minutes) in-progress state, not something an admin filters for. Named
  # "review" rather than "draft" specifically to stay visually/verbally
  # distinct from :drafting (the system is drafting; the admin reviews).
  DELIVERY_STATUSES = %w[scheduled pending skipped sent delivered bounced complained review].freeze
  DESCRIPTION_MAX_LENGTH = 100
  RECIPIENT_NAME_MAX_LENGTH = 100
  RECIPIENT_KEYWORDS_MAX_LENGTH = 100_000

  self.ignored_columns += %i[skip_personalization]
  # TODO(04-2027): Remove this line once DropSkipPersonalizationFromInvites has been promoted.

  rate_limit :limit_invites_per_day

  belongs_to :invited_by, class_name: "User"

  has_many :invited_users
  has_many :users, through: :invited_users
  has_many :invited_groups
  has_many :groups, through: :invited_groups
  has_many :topic_invites
  has_many :topics, through: :topic_invites, source: :topic

  validates :invited_by_id, presence: true
  validates :email, email: true, allow_blank: true
  validates :custom_message, length: { maximum: 1000 }
  validates :custom_subject, length: { maximum: 255 }
  validates :domain, length: { maximum: 500 }
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }
  validates :recipient_name, length: { maximum: RECIPIENT_NAME_MAX_LENGTH }
  validates :recipient_keywords, length: { maximum: RECIPIENT_KEYWORDS_MAX_LENGTH }
  validate :ensure_max_redemptions_allowed
  validate :valid_redemption_count
  validate :valid_domain, if: :will_save_change_to_domain?
  validate :user_doesnt_already_exist, if: :will_save_change_to_email?
  validate :email_xor_domain
  validate :ensure_valid_admin_invite, if: :admin?
  validate :ensure_valid_moderator_invite, if: :moderator?

  before_create do
    self.invite_key ||= SecureRandom.base58(10)
    self.expires_at ||= SiteSetting.invite_expiry_days.days.from_now
  end

  before_save do
    self.email_token = email.present? ? SecureRandom.hex : nil if will_save_change_to_email?

    if will_save_change_to_email? || will_save_change_to_description?
      # allow_any_email rows (and legacy rows predating that column) leave
      # email nil and stash the real intended address in description
      # instead -- fall back to it so the domain filter/resend feature can
      # still find these invites. Only when description actually looks like
      # an email address, so a generic invite-link's free-text description
      # doesn't get misread as a domain.
      domain_source =
        email.presence ||
          (description if description.present? && EmailAddressValidator.valid_value?(description))
      self.email_domain = domain_source&.split("@")&.last&.downcase
    end
  end

  before_validation { self.email = Email.downcase(email) unless email.nil? }
  before_validation :set_skip_email_domain_validation

  # Not a DB column -- mirrors User#skip_email_domain_validation (see
  # set_skip_email_domain_validation below and lib/validators/email_validator.rb, which reads
  # this generically via record.try(:skip_email_domain_validation) for any record type).
  attr_accessor :skip_email_domain_validation

  attribute :email_already_exists

  # ActiveModel::Type::Boolean#cast fails open (anything not in its narrow
  # FALSE_VALUES list, e.g. "no"/"n"/a typo, casts to true), which is wrong
  # for a security-relevant flag filled in free-text by an admin -- only an
  # explicit truthy spelling counts, everything else (including typos)
  # stays false. Mirrors the inline check Jobs::BulkInvite#send_invite has
  # used for this since the CSV columns were introduced.
  def self.truthy_param?(value)
    %w[true t 1 yes y].include?(value.to_s.strip.downcase)
  end

  def self.email_code_enabled?(user = nil)
    UpcomingChanges.enabled_for_user?(:enable_local_logins_via_code, user) &&
      SiteSetting.enable_local_logins && SiteSetting.enable_local_logins_via_email &&
      !SiteSetting.enable_discourse_connect
  end

  def self.emailed_status_types
    @emailed_status_types ||=
      Enum.new(
        not_required: 0,
        pending: 1,
        bulk_pending: 2,
        sending: 3,
        sent: 4,
        skipped: 5,
        # Created (e.g. via Extract-from-URL), sitting on the admin's Pending
        # tab for review before an explicit send -- named "review" rather
        # than "draft" specifically to stay distinct from :drafting below.
        review: 6,
        # Set while Jobs::GenerateInvitePersonalization is generating this
        # invite's AI-personalized content, between an admin triggering a
        # send and the invite becoming :bulk_pending -- see that job's class
        # comment for why this exists as its own status rather than content
        # being generated lazily inside Jobs::ProcessBulkInviteEmails (the
        # old approach let a slow LLM call block that job's send pacing).
        drafting: 7,
      )
  end

  # Staff-sent invites (admin, moderator, or Batch Moderator -- see
  # InviteGuardian#can_skip_email_domain_validation?) skip the site's email-domain allowlist
  # entirely, not just format/blocklist checks -- this is what let 2255 ordinary personal-domain
  # CSV rows get rejected at Invite.create! time in production despite being sent by an admin.
  # invited_by is always a loaded User object by the time this runs (every caller passes the
  # full object, not just an id), so this adds no extra query for the common admin/moderator
  # case -- Guardian#is_staff? short-circuits before the Batch Moderator check ever runs.
  def set_skip_email_domain_validation
    self.skip_email_domain_validation =
      invited_by.present? && Guardian.new(invited_by).can_skip_email_domain_validation?
  end

  def user_doesnt_already_exist
    self.email_already_exists = false
    return if email.blank?
    user = Invite.find_user_by_email(email)

    if user && user.id != invited_users&.first&.user_id
      self.email_already_exists = true
      errors.add(:base, user_exists_error_msg(email))
    end
  end

  def email_xor_domain
    errors.add(:base, I18n.t("invite.email_xor_domain")) if email.present? && domain.present?
  end

  # Even if a domain is specified on the invite, it still counts as
  # an invite link.
  def is_invite_link?
    email.blank?
  end

  # Email invites have specific behaviour and it's easier to visually
  # parse is_email_invite? than !is_invite_link?
  def is_email_invite?
    email.present?
  end

  def redeemable?
    !redeemed? && !expired? && !deleted_at? && !destroyed? && link_valid?
  end

  def redeemed_by_user?(redeeming_user)
    invited_users.exists?(user: redeeming_user)
  end

  def redeemed?
    if is_invite_link?
      redemption_count >= max_redemptions_allowed
    else
      invited_users.count > 0
    end
  end

  def email_matches?(email)
    email.downcase == self.email.downcase
  end

  def domain_matches?(email)
    _, domain = email.split("@")
    self.domain == domain
  end

  def can_be_redeemed_by?(user)
    return false if !redeemable?
    return false if redeemed_by_user?(user)
    return true if domain.blank? && email.blank?
    return true if email.present? && email_matches?(user.email)
    domain.present? && domain_matches?(user.email)
  end

  def expired?
    expires_at < Time.zone.now
  end

  def link(with_email_token: false)
    if with_email_token
      "#{Discourse.base_url}/invites/#{invite_key}?t=#{email_token}"
    else
      "#{Discourse.base_url}/invites/#{invite_key}"
    end
  end

  def link_valid?
    invalidated_at.nil?
  end

  def self.generate(invited_by, opts = nil)
    opts ||= {}
    time_zone = Time.find_zone(invited_by&.user_option&.timezone) || Time.zone
    email = Email.downcase(opts[:email]) if opts[:email].present?

    raise UserExists.new(new.user_exists_error_msg(email)) if find_user_by_email(email)

    if email.present?
      invite =
        Invite
          .with_deleted
          .where(email: email, invited_by_id: invited_by.id)
          .order("created_at DESC")
          .first

      if invite && (invite.expired? || invite.deleted_at)
        invite.destroy
        invite = nil
      end
      email_digest = Digest::SHA256.hexdigest(email)
      RateLimiter.new(
        invited_by,
        "reinvites-per-day-#{email_digest}",
        SiteSetting.invite_reinvite_rate_limit_per_day,
        1.day.to_i,
      ).performed!
    end

    emailed_status =
      if opts[:skip_email] || invite&.emailed_status == emailed_status_types[:not_required]
        emailed_status_types[:not_required]
      elsif opts[:emailed_status].present?
        opts[:emailed_status]
      elsif email.present?
        emailed_status_types[:pending]
      else
        emailed_status_types[:not_required]
      end

    if invite
      was_admin = invite.admin?
      # A re-upload (or resend) of an existing invite must be able to change
      # the per-row personalization context. Only keys actually passed are
      # touched, so callers that don't know about them leave them alone.
      context =
        opts.slice(
          :recipient_name,
          :recipient_keywords,
          :ai_personalization,
          :schedule_send,
          :source_url,
        )
      invite.update!(context) if context.present?
      invite.update_columns(
        created_at: Time.zone.now,
        updated_at: Time.zone.now,
        expires_at: opts[:expires_at] || time_zone.now + SiteSetting.invite_expiry_days.days,
        emailed_status: emailed_status,
        # update_columns skips validations, so the inviter checks from
        # ensure_valid_admin_invite / ensure_valid_moderator_invite have to be
        # re-applied here
        admin: !!opts[:admin] && !!invited_by&.admin?,
        moderator: !!opts[:moderator] && !!invited_by&.staff?,
      )
    else
      create_args =
        opts.slice(
          :email,
          :description,
          :domain,
          :moderator,
          :admin,
          :custom_message,
          :max_redemptions_allowed,
          :recipient_name,
          :recipient_keywords,
          :ai_personalization,
          :schedule_send,
          :allow_any_email,
          :source_url,
        )
      create_args[:invited_by] = invited_by
      create_args[:email] = email
      create_args[:emailed_status] = emailed_status
      create_args[:expires_at] = opts[:expires_at] ||
        time_zone.now + SiteSetting.invite_expiry_days.days

      invite = Invite.create!(create_args)
    end

    DiscourseEvent.trigger(:admin_invite_created, invite) if invite.admin? && !was_admin

    if invite.admin? || invite.moderator?
      # staff invites never carry topic or group associations; clear any left
      # over from a reused member invite
      invite.topic_invites.destroy_all
      invite.invited_groups.destroy_all
    else
      topic_id = opts[:topic]&.id || opts[:topic_id]
      invite.topic_invites.find_or_create_by!(topic_id: topic_id) if topic_id.present?

      group_ids = opts[:group_ids]
      if group_ids.present?
        group_ids.each { |group_id| invite.invited_groups.find_or_create_by!(group_id: group_id) }
      end
    end

    if emailed_status == emailed_status_types[:pending]
      invite.update_column(:emailed_status, emailed_status_types[:sending])
      Jobs.enqueue(:invite_email, invite_id: invite.id, invite_to_topic: opts[:invite_to_topic])
    end

    invite.reload
  end

  def redeem(
    email: nil,
    username: nil,
    name: nil,
    password: nil,
    user_custom_fields: nil,
    ip_address: nil,
    session: nil,
    email_token: nil,
    email_verified: false,
    redeeming_user: nil
  )
    return if !redeemable?

    InviteRedeemer.new(
      invite: self,
      email: email,
      username: username,
      name: name,
      password: password,
      user_custom_fields: user_custom_fields,
      ip_address: ip_address,
      session: session,
      email_token: email_token,
      email_verified: email_verified,
      redeeming_user: redeeming_user,
    ).redeem
  end

  def self.redeem_for_existing_user(user)
    invite = Invite.find_by(email: Email.downcase(user.email))
    if invite.present? && invite.redeemable?
      InviteRedeemer.new(invite: invite, redeeming_user: user).redeem
    end
    invite
  end

  def self.find_user_by_email(email)
    User.with_email(Email.downcase(email)).where(staged: false).first
  end

  # A :review invite only ever shows up here when explicitly filtered to the
  # "review" status -- with no status filter, it stays excluded (same as
  # before this status existed), so the ordinary Pending view isn't
  # cluttered with invites nobody has reviewed/sent yet.
  # :id tiebreaker on the order -- a bulk draft-creation request can insert
  # hundreds of rows sharing the same updated_at, and OFFSET/LIMIT over a
  # non-unique ORDER BY isn't guaranteed stable across requests, so the
  # status=review view's infinite scroll could skip or repeat rows without it.
  def self.pending(inviter, domain: nil, status: nil)
    invites =
      Invite
        .distinct
        .joins("LEFT JOIN invited_users ON invites.id = invited_users.invite_id")
        .joins("LEFT JOIN users ON invited_users.user_id = users.id")
        .where(invited_by_id: inviter.id)
        .where("redemption_count < max_redemptions_allowed")
        .where("expires_at > ?", Time.zone.now)
        .order("invites.updated_at DESC, invites.id DESC")
    invites = invites.where(*domain_filter_condition(domain)) if domain.present?
    if status.present?
      invites = with_delivery_status(invites, status)
    else
      invites =
        invites.where(
          "emailed_status IS NULL OR emailed_status NOT IN (?)",
          emailed_status_types.values_at(:review, :drafting),
        )
    end
    invites
  end

  def self.expired(inviter, domain: nil, status: nil)
    invites =
      Invite
        .distinct
        .joins("LEFT JOIN invited_users ON invites.id = invited_users.invite_id")
        .joins("LEFT JOIN users ON invited_users.user_id = users.id")
        .where(invited_by_id: inviter.id)
        .where("redemption_count < max_redemptions_allowed")
        .where("expires_at < ?", Time.zone.now)
        .where(
          "emailed_status IS NULL OR emailed_status NOT IN (?)",
          emailed_status_types.values_at(:review, :drafting),
        )
        .order("invites.expires_at ASC")
    invites = invites.where(*domain_filter_condition(domain)) if domain.present?
    invites = with_delivery_status(invites, status) if status.present?
    invites
  end

  # Invites a Jobs::GenerateInvitePersonalization run has claimed but not yet
  # finished generating content for -- a ready-made hook for a future "N
  # invites still generating" UI affordance, mirroring .pending/.expired's
  # own scope convention.
  def self.drafting
    where(emailed_status: emailed_status_types[:drafting])
  end

  def self.redeemed_users(inviter, domain: nil)
    invited_users =
      InvitedUser
        .joins("LEFT JOIN invites ON invites.id = invited_users.invite_id")
        .includes(user: :user_stat)
        .where.not(user_id: nil)
        .where("invites.invited_by_id = ?", inviter.id)
        .order("invited_users.redeemed_at DESC")
        .references("invite")
        .references("user")
        .references("user_stat")
    invited_users = invited_users.where(*domain_filter_condition(domain)) if domain.present?
    invited_users
  end

  # Shared by pending/expired/redeemed_users so the "ac.in" umbrella special
  # case lives in exactly one place. The LIKE branch has a leading wildcard,
  # so it can't use a standard btree index on email_domain -- a sequential
  # scan per inviter is acceptable at current scale (thousands, not millions,
  # of invites), but worth knowing if that scale changes.
  def self.domain_filter_condition(domain)
    if domain == AC_IN_UMBRELLA_DOMAIN
      [
        "invites.email_domain = :domain OR invites.email_domain LIKE :suffix",
        { domain: domain, suffix: "%.#{domain}" },
      ]
    else
      ["invites.email_domain = :domain", { domain: domain }]
    end
  end
  private_class_method :domain_filter_condition

  # Shared by UsersController#invited (the listing) and
  # InvitesController#resend_all_invites, so bulk resend always matches
  # exactly the rows the admin can currently see under the same search term.
  # allow_any_email invites have no bound invites.email -- their intended
  # recipient lives in invites.description instead (see Jobs::BulkInvite),
  # so search has to check both or those invites are invisible to search
  # despite being real and findable by scrolling the unfiltered list.
  def self.search_filter(invites, search, show_emails:)
    return invites if search.blank?

    filter_sql = "(LOWER(users.username) LIKE :filter)"
    filter_sql =
      "(LOWER(invites.email) LIKE :filter) or (LOWER(invites.description) LIKE :filter) or (LOWER(invites.source_url) LIKE :filter) or (LOWER(users.username) LIKE :filter)" if show_emails

    invites.where(filter_sql, filter: "%#{search.downcase}%")
  end

  def self.invalidate_for_email(email)
    Invite.find_by(email: Email.downcase(email))&.invalidate!
  end

  def invalidate!
    update_attribute(:invalidated_at, Time.current)
    self
  end

  def resend_invite
    update_columns(
      updated_at: Time.zone.now,
      invalidated_at: nil,
      expires_at: SiteSetting.invite_expiry_days.days.from_now,
    )
    Jobs.enqueue(:invite_email, invite_id: id)
  end

  # Used by InvitesController#resend_all_invites instead of resend_invite,
  # when SiteSetting.bulk_invite_paced_resend_enabled is on: resend_invite
  # sends immediately (fine for a single admin-triggered resend), but firing
  # it in a loop for every pending invite is exactly the kind of undelayed
  # burst send Jobs::ProcessBulkInviteEmails exists to avoid. This instead
  # re-queues the invite the same way a fresh bulk CSV row does, so the
  # existing one-at-a-time, randomly-paced throttle (and AI personalization,
  # if enabled) picks it up rather than mailing it out immediately.
  def requeue_for_paced_resend
    update_columns(
      updated_at: Time.zone.now,
      invalidated_at: nil,
      expires_at: SiteSetting.invite_expiry_days.days.from_now,
      emailed_status: Invite.emailed_status_types[:bulk_pending],
    )
  end

  # Used by InvitesController#send_now_invite ("Send Now") to pull one invite
  # out of the paced queue immediately. The WHERE clause on the UPDATE itself
  # is what makes this race-safe against Jobs::ProcessBulkInviteEmails'
  # concurrent claim_next_pending_invite -- it only succeeds if the row was
  # still bulk_pending/pending the instant the UPDATE ran, so the two can
  # never both claim (and double-send) the same invite.
  def self.claim_for_immediate_send(id)
    claimable_statuses = emailed_status_types.values_at(:pending, :bulk_pending)
    claimed_count =
      where(id: id, emailed_status: claimable_statuses).update_all(
        emailed_status: emailed_status_types[:sending],
        updated_at: Time.zone.now,
      )
    claimed_count == 1 ? find_by(id: id) : nil
  end

  # Atomically flips a batch of pre-existing invites into :drafting, for a
  # caller about to enqueue Jobs::GenerateInvitePersonalization. Called by
  # InvitesController#dispatch_bulk_resend *before* enqueueing (not by the
  # job itself) -- this is what makes the :review -> :drafting transition
  # happen synchronously, as part of the HTTP response, rather than only
  # once Sidekiq gets around to running the job. That matters: the status
  # change is the admin's only way to tell a batch they just dispatched
  # apart from an unrelated newer batch still sitting at :review, and a
  # Sidekiq lag (a deploy restarting workers, a backed-up queue) shouldn't
  # leave that indistinguishable for minutes or hours.
  #
  # A single conditional UPDATE, not a find_each+save loop -- so two
  # concurrent callers (e.g. an admin double-clicking "Send Selected")
  # can't both claim, and both regenerate content for, the same invite.
  # Mirrors #claim_for_immediate_send's same reasoning. Returns only the
  # ids actually claimed; a caller enqueues the job with just those (if
  # any) rather than the originally-requested set -- an invite that's
  # already mid-flight elsewhere is a legitimate race to skip quietly, not
  # a reason to fail the whole batch.
  #
  # Jobs::BulkInvite doesn't call this: it creates brand-new rows already
  # at :drafting (see #generate), so there's nothing pre-existing to race
  # against.
  #
  # "emailed_status IS NULL OR ..." -- not just a plain where.not, which
  # would silently exclude every NULL row instead of claiming it: SQL's
  # NOT IN against NULL evaluates to NULL (neither true nor false), so a
  # row with no emailed_status set yet would never be claimable without
  # this. #pending/#expired already guard against this same gap.
  def self.claim_for_drafting(invite_ids)
    return [] if invite_ids.blank?

    in_flight_statuses = emailed_status_types.values_at(:drafting, :bulk_pending, :sending)
    claimable_ids =
      where(id: invite_ids).where(
        "emailed_status IS NULL OR emailed_status NOT IN (?)",
        in_flight_statuses,
      ).pluck(:id)
    return [] if claimable_ids.empty?

    where(id: claimable_ids).update_all(
      emailed_status: emailed_status_types[:drafting],
      updated_at: Time.zone.now,
    )
    claimable_ids
  end

  # #claim_for_drafting's own exclusion of already-:drafting rows (so two
  # concurrent dispatches can't double-claim) has a failure mode: if the
  # Jobs::GenerateInvitePersonalization run that did the claiming dies
  # before finishing -- a deploy restarting Sidekiq mid-batch, a crash,
  # anything -- those invites are claimed forever, with nothing able to
  # reclaim them (confirmed in production: a batch sat at :drafting for
  # hours, untouched, after exactly this). Run periodically (see
  # Jobs::Scheduled::RequeueStaleDraftingInvites) to rewind anything stuck
  # past STALE_DRAFTING_AFTER back to :review, so an admin's next Send
  # Selected -- or this same sweep's own next pass, for an unattended site
  # -- claims and reprocesses it.
  #
  # The threshold has to clear legitimate processing time, not just a
  # single call's worst case (confirmed up to ~367s): a large batch is
  # worked through in small concurrent slices (see
  # Jobs::GenerateInvitePersonalization#execute), so an invite near the
  # end of a big batch can sit untouched, still genuinely queued behind
  # earlier slices, for a while -- 1 hour stays well clear of that even
  # for an unusually large batch, while still being far short of "stuck
  # forever".
  STALE_DRAFTING_AFTER = 1.hour

  def self.requeue_stale_drafting
    where(emailed_status: emailed_status_types[:drafting]).where(
      "updated_at < ?",
      STALE_DRAFTING_AFTER.ago,
    ).update_all(emailed_status: emailed_status_types[:review], updated_at: Time.zone.now)
  end

  def limit_invites_per_day
    RateLimiter.new(invited_by, "invites-per-day", SiteSetting.max_invites_per_day, 1.day.to_i)
  end

  # The EmailLog row for the most recent invite email actually sent for this
  # invite (if any) -- distinct from custom_message, which only holds the
  # note as currently written and gets overwritten on every AI-personalization
  # pass (see BulkInvitePersonalization::Generator) or resend, losing any
  # record of what a prior send actually contained.
  def latest_sent_email_log
    EmailLog.where(invite_id: id, email_type: "invite").order(created_at: :desc).first
  end

  # Downstream delivery outcome (sourced from SES via the linked EmailLog),
  # distinct from emailed_status above -- that enum only tracks whether we
  # handed the email to the mailer, not what happened after. Not folded into
  # emailed_status itself since that would conflate "did we try to send" with
  # "what happened once we did", which have different lifecycles (a bounce
  # can arrive seconds or days after emailed_status already reads "sent").
  # Accepts an optional preloaded EmailLog so callers rendering a page of
  # invites (see UsersController#invited) can batch-load it once and avoid an
  # EmailLog query per invite.
  def delivery_status(email_log = latest_sent_email_log)
    case emailed_status
    when Invite.emailed_status_types[:review], Invite.emailed_status_types[:drafting]
      "review"
    when Invite.emailed_status_types[:not_required]
      nil
    when Invite.emailed_status_types[:pending], Invite.emailed_status_types[:bulk_pending]
      "scheduled"
    when Invite.emailed_status_types[:sending]
      "pending"
    when Invite.emailed_status_types[:skipped]
      "skipped"
    else
      return "sent" if email_log.nil?
      return "complained" if email_log.complained_at
      return "bounced" if email_log.bounced?
      return "delivered" if email_log.delivered_at
      "sent"
    end
  end

  # SQL counterpart of #delivery_status for filtering a relation of invites.
  # The two must stay in step -- spec/models/invite_spec.rb checks every
  # status against both.
  def self.with_delivery_status(relation, status)
    types = emailed_status_types

    case status.to_s
    when "scheduled"
      relation.where(emailed_status: [types[:pending], types[:bulk_pending]])
    when "pending"
      relation.where(emailed_status: types[:sending])
    when "skipped"
      relation.where(emailed_status: types[:skipped])
    when "review"
      relation.where(emailed_status: types.values_at(:review, :drafting))
    when "sent", "delivered", "bounced", "complained"
      outcome =
        case status.to_s
        when "complained"
          "latest_log.complained_at IS NOT NULL"
        when "bounced"
          "latest_log.complained_at IS NULL AND latest_log.bounced"
        when "delivered"
          "latest_log.complained_at IS NULL AND NOT latest_log.bounced AND latest_log.delivered_at IS NOT NULL"
        when "sent"
          "latest_log.id IS NULL OR (latest_log.complained_at IS NULL AND NOT latest_log.bounced AND latest_log.delivered_at IS NULL)"
        end

      relation
        .joins(<<~SQL)
          LEFT JOIN LATERAL (
            SELECT email_logs.id, email_logs.complained_at, email_logs.bounced, email_logs.delivered_at
            FROM email_logs
            WHERE email_logs.invite_id = invites.id AND email_logs.email_type = 'invite'
            ORDER BY email_logs.created_at DESC
            LIMIT 1
          ) latest_log ON TRUE
        SQL
        .where(
          "invites.emailed_status IS NULL OR invites.emailed_status NOT IN (?)",
          types.values_at(
            :not_required,
            :pending,
            :bulk_pending,
            :sending,
            :skipped,
            :review,
            :drafting,
          ),
        )
        .where(outcome)
    else
      relation.none
    end
  end

  def self.base_directory
    Rails.public_path.join("uploads", "csv", RailsMultisite::ConnectionManagement.current_db).to_s
  end

  def ensure_max_redemptions_allowed
    if max_redemptions_allowed.nil?
      self.max_redemptions_allowed = 1
    else
      limit =
        (
          if invited_by&.staff?
            SiteSetting.invite_link_max_redemptions_limit
          else
            SiteSetting.invite_link_max_redemptions_limit_users
          end
        )

      if (admin? || moderator?) && max_redemptions_allowed != 1
        errors.add(:max_redemptions_allowed, I18n.t("invite.max_redemptions_allowed_one_staff"))
      elsif email.present? && max_redemptions_allowed != 1
        errors.add(:max_redemptions_allowed, I18n.t("invite.max_redemptions_allowed_one"))
      elsif !max_redemptions_allowed.between?(1, limit)
        errors.add(
          :max_redemptions_allowed,
          I18n.t("invite_link.max_redemptions_limit", max_limit: limit),
        )
      end
    end
  end

  def valid_redemption_count
    if redemption_count > max_redemptions_allowed
      errors.add(
        :redemption_count,
        I18n.t(
          "invite.redemption_count_less_than_max",
          max_redemptions_allowed: max_redemptions_allowed,
        ),
      )
    end
  end

  def ensure_valid_admin_invite
    # checked when the flag is set or the invite's reach changes (removing
    # the email or domain restriction widens who can redeem it), but not on
    # unrelated saves (e.g. marking the invite redeemed) so they don't fail
    # if the inviter has since been demoted
    if (
         new_record? || will_save_change_to_admin? || will_save_change_to_email? ||
           will_save_change_to_domain?
       ) && !invited_by&.admin?
      errors.add(:base, I18n.t("invite.admin_invite_requires_admin_inviter"))
    end
  end

  def ensure_valid_moderator_invite
    # checked when the flag is set or the invite's reach changes (removing
    # the email or domain restriction widens who can redeem it), but not on
    # unrelated saves (e.g. marking the invite redeemed) so they don't fail
    # if the inviter has since been demoted
    if (
         new_record? || will_save_change_to_moderator? || will_save_change_to_email? ||
           will_save_change_to_domain?
       ) && !invited_by&.staff?
      errors.add(:base, I18n.t("invite.moderator_invite_requires_staff_inviter"))
    end
  end

  def valid_domain
    return if domain.blank?

    domain.downcase!

    errors.add(:base, I18n.t("invite.domain_not_allowed_admin")) if domain !~ Invite::DOMAIN_REGEX
  end

  def user_exists_error_msg(email)
    error_key = SiteSetting.hide_email_address_taken? ? "generic_error_response" : "user_exists"

    I18n.t("invite.#{error_key}", email: CGI.escapeHTML(email))
  end
end

# == Schema Information
#
# Table name: invites
#
#  id                      :integer          not null, primary key
#  admin                   :boolean          default(FALSE), not null
#  ai_personalization      :boolean          default(TRUE), not null
#  allow_any_email         :boolean          default(FALSE), not null
#  custom_message          :text
#  custom_subject          :string
#  deleted_at              :datetime
#  description             :string(100)
#  domain                  :string
#  email                   :string
#  email_domain            :string
#  email_token             :string
#  emailed_status          :integer
#  expires_at              :datetime         not null
#  invalidated_at          :datetime
#  invite_key              :string(32)       not null
#  max_redemptions_allowed :integer          default(1), not null
#  moderator               :boolean          default(FALSE), not null
#  recipient_keywords      :text
#  recipient_name          :string(100)
#  redemption_count        :integer          default(0), not null
#  schedule_send           :boolean          default(TRUE), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  deleted_by_id           :integer
#  invited_by_id           :integer          not null
#
# Indexes
#
#  index_invites_on_email_and_invited_by_id         (email,invited_by_id)
#  index_invites_on_emailed_status                  (emailed_status)
#  index_invites_on_invite_key                      (invite_key) UNIQUE
#  index_invites_on_invited_by_id                   (invited_by_id)
#  index_invites_on_invited_by_id_and_email_domain  (invited_by_id,email_domain) WHERE (email_domain IS NOT NULL)
#
