# frozen_string_literal: true

RSpec.describe BatchModeration::GroupSync do
  fab!(:college_field) { Fabricate(:user_field, name: "College", requirement: "optional") }
  fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
  fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }
  fab!(:type_field) { Fabricate(:user_field, name: "I am", requirement: "optional") }
  fab!(:user)

  before { SiteSetting.enable_batch_moderation = true }

  def set_field(user, field, value)
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{field.id}"] = value if value
    user.save_custom_fields(true, run_validations: false)
  end

  def set_student(user, college:, branch: nil, batch:)
    set_field(user, college_field, college)
    set_field(user, branch_field, branch)
    set_field(user, batch_field, batch)
  end

  def set_staff(user, college:)
    set_field(user, college_field, college)
    set_field(user, type_field, "Dean/Professor/Staff")
  end

  describe ".sync" do
    it "does nothing when the site setting is disabled" do
      SiteSetting.enable_batch_moderation = false
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

      expect { described_class.sync(user) }.not_to change { Group.count }
    end

    it "does nothing when College is blank, even with Branch/Batch present" do
      set_field(user, branch_field, "CSE")
      set_field(user, batch_field, "2024")

      expect { described_class.sync(user) }.not_to change { Group.count }
    end

    it "does nothing when Batch is blank for a Student-type member" do
      set_field(user, college_field, "MNIT Jaipur")

      expect { described_class.sync(user) }.not_to change { Group.count }
    end

    it "truncates a long combined key into full_name instead of raising" do
      set_student(user, college: "C" * 90, branch: "CSE", batch: "2024")

      expect { described_class.sync(user) }.not_to raise_error

      expect(Group.last.full_name.length).to be <= 100
    end

    it "creates a College+Branch+Batch group for a Student-type member and adds them" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

      expect { described_class.sync(user) }.to change { Group.count }.by(1)

      group = Group.last
      expect(described_class.batch_group?(group)).to eq(true)
      expect(group.full_name).to eq("MNIT Jaipur · 2024 · CSE")
      expect(group.users).to include(user)
    end

    it "creates a College-only group for a Staff-type member, ignoring Branch/Batch" do
      set_staff(user, college: "MNIT Jaipur")
      set_field(user, branch_field, "CSE")
      set_field(user, batch_field, "2024")

      expect { described_class.sync(user) }.to change { Group.count }.by(1)

      group = Group.last
      expect(group.full_name).to eq("MNIT Jaipur · Staff")
      expect(group.users).to include(user)
    end

    it "reuses the existing group for the same key" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      other_user = Fabricate(:user)
      set_student(other_user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

      expect { described_class.sync(other_user) }.not_to change { Group.count }
      expect(Group.last.users).to include(user, other_user)
    end

    it "puts a Student and a Staff member from the same College in different groups" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      staff_user = Fabricate(:user)
      set_staff(staff_user, college: "MNIT Jaipur")

      expect { described_class.sync(staff_user) }.to change { Group.count }.by(1)
      expect(Group.last.users).to include(staff_user)
      expect(Group.last.users).not_to include(user)
    end

    it "moves the user out of their old cohort group when their fields change" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)
      old_group = Group.last

      set_student(user, college: "MNIT Jaipur", branch: "ECE", batch: "2025")
      described_class.sync(user)

      expect(old_group.reload.users).not_to include(user)
      new_group = Group.where.not(id: old_group.id).order(:id).last
      expect(new_group.users).to include(user)
    end

    it "moves a member from a Student cohort to a Staff cohort when their type field changes" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)
      student_group = Group.last

      set_staff(user, college: "MNIT Jaipur")
      described_class.sync(user)

      expect(student_group.reload.users).not_to include(user)
      staff_group = Group.where.not(id: student_group.id).order(:id).last
      expect(staff_group.full_name).to eq("MNIT Jaipur · Staff")
      expect(staff_group.users).to include(user)
    end

    it "is a no-op if the cohort key does not change" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      expect { described_class.sync(user) }.not_to change { Group.count }
    end

    it "notifies on cohort join and leave" do
      allow(BatchModeration::Notifier).to receive(:notify_cohort_change)

      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      expect(BatchModeration::Notifier).to have_received(:notify_cohort_change).with(
        user: user,
        group: an_instance_of(Group),
        joined: true,
      )

      set_student(user, college: "MNIT Jaipur", branch: "ECE", batch: "2025")
      described_class.sync(user)

      expect(BatchModeration::Notifier).to have_received(:notify_cohort_change).with(
        user: user,
        group: an_instance_of(Group),
        joined: false,
      )
      expect(BatchModeration::Notifier).to have_received(:notify_cohort_change).with(
        user: user,
        group: an_instance_of(Group),
        joined: true,
      ).twice
    end

    it "does not notify at all when notify: false (used by the resync_cohorts backfill task)" do
      allow(BatchModeration::Notifier).to receive(:notify_cohort_change)
      allow(BatchModeration::Notifier).to receive(:notify_moderator_status_change)

      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user, notify: false)

      expect(BatchModeration::Notifier).not_to have_received(:notify_cohort_change)
      expect(BatchModeration::Notifier).not_to have_received(:notify_moderator_status_change)
    end

    it "notifies a revoke when a stale-group removal strips owner status" do
      SiteSetting.batch_moderation_auto_promote_count = 1
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)
      old_group = Group.last
      expect(old_group.group_users.find_by(user_id: user.id).owner).to eq(true)

      allow(BatchModeration::Notifier).to receive(:notify_moderator_status_change)
      set_student(user, college: "MNIT Jaipur", branch: "ECE", batch: "2025")
      described_class.sync(user)

      expect(BatchModeration::Notifier).to have_received(:notify_moderator_status_change).with(
        actor: nil,
        user: user,
        group: old_group,
        granted: false,
      )
    end
  end

  describe ".sync on a site with no institution field configured at all" do
    before { college_field.destroy! }

    it "never forms a cohort group, even with Batch/Branch present" do
      set_field(user, branch_field, "CSE")
      set_field(user, batch_field, "2024")

      expect { described_class.sync(user) }.not_to change { Group.count }
    end
  end

  describe ".sync on a site with Vidyalaya instead of College (e.g. navodians.com)" do
    before { college_field.destroy! }

    fab!(:vidyalaya_field) { Fabricate(:user_field, name: "Vidyalaya", requirement: "optional") }

    def set_vidyalaya_student(user, vidyalaya:, batch:)
      set_field(user, vidyalaya_field, vidyalaya)
      set_field(user, batch_field, batch)
    end

    it "creates a Vidyalaya+Batch cohort group" do
      set_vidyalaya_student(user, vidyalaya: "JNV Delhi", batch: "1998")

      expect { described_class.sync(user) }.to change { Group.count }.by(1)

      group = Group.last
      expect(group.full_name).to eq("JNV Delhi · 1998")
      expect(group.users).to include(user)
    end

    it "does not group two users from different Vidyalayas together even with the same Batch" do
      set_vidyalaya_student(user, vidyalaya: "JNV Delhi", batch: "1998")
      described_class.sync(user)

      other_user = Fabricate(:user)
      set_vidyalaya_student(other_user, vidyalaya: "JNV Mumbai", batch: "1998")

      expect { described_class.sync(other_user) }.to change { Group.count }.by(1)
      expect(Group.last.users).to include(other_user)
      expect(Group.last.users).not_to include(user)
    end
  end

  describe ".sync on a site with no member-type field (e.g. iitians.in today)" do
    before { type_field.destroy! }

    it "treats every member as Student-type, unchanged from today's behavior" do
      set_student(user, college: "IIT Delhi", batch: "2024")

      expect { described_class.sync(user) }.to change { Group.count }.by(1)

      group = Group.last
      expect(group.full_name).to eq("IIT Delhi · 2024")
    end
  end

  describe "auto-promotion of the first N joiners to batch moderator" do
    before { SiteSetting.batch_moderation_auto_promote_count = 2 }

    def join(branch: "CSE", batch: "2024")
      joiner = Fabricate(:user)
      set_student(joiner, college: "MNIT Jaipur", branch: branch, batch: batch)
      described_class.sync(joiner)
      joiner
    end

    it "auto-promotes the first N joiners to owner" do
      first = join
      second = join

      group = Group.last
      expect(group.group_users.find_by(user_id: first.id).owner).to eq(true)
      expect(group.group_users.find_by(user_id: second.id).owner).to eq(true)
    end

    it "stops auto-promoting once the group already has N owners" do
      join
      join
      third = join

      group = Group.last
      expect(group.group_users.find_by(user_id: third.id).owner).to eq(false)
      expect(group.group_users.where(owner: true).count).to eq(2)
    end

    it "does not auto-promote when the count setting is 0" do
      SiteSetting.batch_moderation_auto_promote_count = 0

      first = join

      group = Group.last
      expect(group.group_users.find_by(user_id: first.id).owner).to eq(false)
    end
  end

  describe ".batch_group?" do
    it "returns false for a regular group" do
      expect(described_class.batch_group?(Fabricate(:group))).to eq(false)
    end

    it "returns true for an auto-provisioned batch group" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      expect(described_class.batch_group?(Group.last)).to eq(true)
    end
  end

  describe ".batch_group_for" do
    it "returns nil for a user with no cohort group" do
      expect(described_class.batch_group_for(user)).to be_nil
    end

    it "returns the user's single batch group" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      expect(described_class.batch_group_for(user)).to eq(Group.last)
    end
  end

  describe ".staff_type_user_ids" do
    it "returns the ids of staff-type users among the given ids" do
      set_staff(user, college: "MNIT Jaipur")
      student = Fabricate(:user)
      set_student(student, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

      expect(described_class.staff_type_user_ids([user.id, student.id])).to eq(Set[user.id])
    end

    it "returns an empty set when given no ids" do
      expect(described_class.staff_type_user_ids([])).to eq(Set.new)
    end

    it "returns an empty set when the site has no member-type field configured" do
      UserField.where(name: "I am").delete_all
      set_field(user, college_field, "MNIT Jaipur")

      expect(described_class.staff_type_user_ids([user.id])).to eq(Set.new)
    end
  end

  describe ".all_staff_type_user_ids" do
    it "composes into a WHERE id IN (...) subquery matching staff-type users" do
      set_staff(user, college: "MNIT Jaipur")
      student = Fabricate(:user)
      set_student(student, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

      ids = User.where(id: described_class.all_staff_type_user_ids).pluck(:id)
      expect(ids).to contain_exactly(user.id)
    end

    it "matches nothing when the site has no member-type field configured" do
      UserField.where(name: "I am").delete_all
      set_field(user, college_field, "MNIT Jaipur")

      ids = User.where(id: described_class.all_staff_type_user_ids).pluck(:id)
      expect(ids).to be_empty
    end
  end

  # Exercises the orphaned-batch-group query used by the
  # `batch_moderation:resync_cohorts` rake task, independent of the task's
  # RailsMultisite::ConnectionManagement.each_connection wrapper (which
  # interacts awkwardly with RSpec's per-example transactional fixtures in a
  # multisite test run -- see spec/tasks/batch_moderation_spec.rb for the
  # task-level coverage).
  describe "orphaned cohort group query" do
    def orphaned_batch_groups
      Group
        .joins(:_custom_fields)
        .where(group_custom_fields: { name: described_class::CUSTOM_FIELD_FLAG, value: "t" })
        .where
        .missing(:group_users)
    end

    it "finds a batch group with zero remaining members" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)
      group = Group.last

      group.remove(user)

      expect(orphaned_batch_groups.pluck(:id)).to include(group.id)
    end

    it "excludes a batch group that still has members" do
      set_student(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")
      described_class.sync(user)

      expect(orphaned_batch_groups.pluck(:id)).not_to include(Group.last.id)
    end

    it "excludes a regular (non-batch) group with zero members" do
      empty_group = Fabricate(:group)

      expect(orphaned_batch_groups.pluck(:id)).not_to include(empty_group.id)
    end
  end
end
