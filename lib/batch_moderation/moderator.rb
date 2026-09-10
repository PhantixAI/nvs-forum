# frozen_string_literal: true

module BatchModeration
  module Moderator
    def self.can_moderate?(actor, target)
      actor != target && shares_batch_group?(actor, target) && !peer_owner?(actor, target)
    end

    def self.can_report?(actor, target)
      shares_batch_group?(actor, target) && actor != target
    end

    def self.shares_batch_group?(actor, target)
      return false unless SiteSetting.enable_batch_moderation
      return false if actor.nil? || target.nil? || target.staff?

      owned_groups = GroupSync.owned_batch_groups(actor).to_a
      return false if owned_groups.empty?

      owned_groups.any? { |group| group.users.include?(target) }
    end

    def self.peer_owner?(actor, target)
      owned_groups = GroupSync.owned_batch_groups(actor).to_a
      owned_groups.any? do |group|
        group.users.include?(target) && group.users.where("group_users.owner").include?(target)
      end
    end
    private_class_method :peer_owner?
  end
end
