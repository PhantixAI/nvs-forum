# frozen_string_literal: true

# Renames each category's "About the X category" topic to a more attractive,
# content-derived title. Only touches topics whose title is still exactly the
# default "About the <category name> category" pattern (categories already
# renamed by someone else, or categories still on Discourse's unedited
# placeholder description, are left untouched).
#
# Usage:
#   SITES=nitians bin/rails runner script/nvs-features/retitle-category-about-topics.rb
#   SITES=nitians,iitians,navodians APPLY=1 bin/rails runner script/nvs-features/retitle-category-about-topics.rb
#
# Dry-run (default): prints what would change, changes nothing.
# APPLY=1: performs the rename via PostRevisor (keeps edit history), as the
# system user.

SITES = ENV.fetch("SITES", "nitians").split(",")
APPLY = ENV["APPLY"] == "1"

TITLES = {
  "nitians" => {
    "Site Feedback" => "Site Feedback & Suggestions",
    "Staff" => "Staff Discussions",
    "General" => "General Discussion",
    "Achievements" => "NITians Achievements: Your Spotlight Moment",
    "Businesses" => "The NITians Business Hub",
    "Deals" => "NITians Deals: Buy, Sell & Trade Together",
    "Support" => "NITians Support: No Question Too Small",
    "Jobs" => "NITians Job Postings & Career Opportunities",
    "Ideas" => "NITian Minds: Beyond Conversation, Into Conviction",
    "Research" => "A Space Where NITian Curiosity Turns Into Knowledge",
    "Placements" => "Placements: The Central Hub for Recruitment Season",
    "Editorial" => "Editorial: Where Thoughts Shape the Narrative",
    "Design & Arch" => "A Space Where NITian Vision Turns Into Built Reality",
    "Audit & Accounts" => "Where Financial Insight Builds Business Integrity",
    "Technology" => "Where Innovation Meets Technological Breakthroughs",
  },
  "iitians" => {
    "Site Feedback" => "Site Feedback & Suggestions",
    "Staff" => "Staff Discussions",
    "General" => "General Discussion",
    "Achievements" => "APEX Achievements: Your Spotlight Moment",
    "Businesses" => "The APEX Business Hub",
    "Deals" => "APEX Deals: Buy, Sell & Trade Together",
    "Support" => "APEX Support: No Question Too Small",
    "Jobs" => "APEX Job Postings & Career Opportunities",
    "Ideas" => "The Best Ideas From India's Best Institutions",
    "Research" => "A Space Where APEX Curiosity Turns Into Knowledge",
    "Placements" => "Placements: The Central Hub for Recruitment Season",
    "Editorial" => "Editorial: Where Analysis Frames the Debate",
    "Design & Arch" => "Where APEX Insights Turn Into Structural Innovation",
    "Audit & Accounts" => "Where APEX Expertise Turns Into Financial Rigor",
  },
  "navodians" => {
    "Site Feedback" => "Site Feedback & Suggestions",
    "Staff" => "Staff Discussions",
    "General" => "General Discussion",
    "Memories" => "Navodian Memories: Where JNV Days Come Alive",
    "Deals" => "Navodians Deals: Buy, Sell & Trade Together",
    "Achievements" => "Navodians Achievements: Your Spotlight Moment",
    "Help" => "Navodians Help: Ask, Learn, Get Answers",
    "Businesses" => "The Navodians Business Hub",
    "Events" => "Navodian Events: The Community Calendar",
    "Meetups" => "Navodian Meetups: Closer, One City at a Time",
    "Social-Work" => "Navodian Social Work: Giving Back Together",
    "Reunion" => "Navodian Reunions: Finding Each Other Again",
    "Alumni-Meet" => "Navodian Alumni Meets: Where We Came From",
    "Jobs" => "Navodians Job Postings & Career Opportunities",
    "Discussions" => "Navodian Discussions: The Open Floor",
    "Support" => "Navodians Support: No Question Too Small",
    "Ideas" => "Navodian Minds: Beyond Conversation, Into Conviction",
    "Research" => "A Space Where Navodian Curiosity Turns Knowledge",
    "Editorial" => "Editorial: Every Voice Has a Story",
    "Audit & Accounts" => "Where Navodian Finance Questions Find Answers",
    "Design & Arch" => "Where Navodian Spaces Turn Into Lasting Structures",
    "Technology" => "Where Navodian Curiosity Turns Into Discovery",
  },
}.freeze

# Connections that share a physical database also share the caches touched by
# a topic title update, but title changes have no theme/site-setting cache to
# refresh (unlike script/nvs-features/apply-cursor-look.rb) — nothing to do
# beyond the normal ActiveRecord write here.

SITES.each do |site|
  unless RailsMultisite::ConnectionManagement.has_db?(site)
    puts "[#{site}] no such connection, skipping"
    next
  end

  titles = TITLES[site]
  unless titles
    puts "[#{site}] no title map defined, skipping"
    next
  end

  RailsMultisite::ConnectionManagement.with_connection(site) do
    puts "===== #{site} (#{APPLY ? "APPLY" : "dry run"}) ====="

    titles.each do |category_name, new_title|
      category = Category.find_by(name: category_name)
      if category.nil?
        puts "  [skip] category #{category_name.inspect} not found"
        next
      end

      topic = category.topic
      if topic.nil?
        puts "  [skip] #{category_name}: category has no topic"
        next
      end

      expected_old_title = "About the #{category_name} category"
      if topic.title != expected_old_title
        puts "  [skip] #{category_name}: title is #{topic.title.inspect}, " \
               "not the expected #{expected_old_title.inspect} (already renamed?)"
        next
      end

      puts "  #{category_name}: #{topic.title.inspect} -> #{new_title.inspect}"

      next unless APPLY

      post = topic.first_post
      revisor = PostRevisor.new(post, topic)
      success = revisor.revise!(Discourse.system_user, { title: new_title }, skip_validations: true)
      puts "    [warn] revision failed" unless success
    end
  end
end

puts APPLY ? "DONE (applied)" : "DONE (dry run, no changes made)"
