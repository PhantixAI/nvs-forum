# frozen_string_literal: true

# The index on email_domain is added by AddIndexToInvitesEmailDomain, which
# builds it concurrently.
class AddEmailDomainToInvites < ActiveRecord::Migration[8.0]
  def up
    add_column :invites, :email_domain, :string, null: true
  end

  def down
    remove_column :invites, :email_domain if column_exists?(:invites, :email_domain)
  end
end
