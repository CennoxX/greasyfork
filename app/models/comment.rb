require 'memoist'

class Comment < ApplicationRecord
  extend Memoist
  include HasAttachments
  include SoftDeletable
  include MentionsUsers
  include CommentIndexing

  belongs_to :discussion
  # Optional because the user may no longer exist.
  belongs_to :poster, class_name: 'User', optional: true
  has_many :reports, as: :item, dependent: :destroy

  validates :text, presence: true, length: { maximum: 65_535 }
  validates :text_markup, inclusion: { in: %w[html markdown] }, presence: true

  delegate :script, :discussion_category, to: :discussion

  strip_attributes only: :text

  def path(locale: nil)
    discussion_path = discussion.path(locale:)
    discussion_path += "#comment-#{id}" unless first_comment?
    discussion_path
  end

  def url(locale: nil)
    discussion_url = discussion.url(locale:)
    discussion_url += "#comment-#{id}" unless first_comment?
    discussion_url
  end

  before_create :set_plain_text
  before_update do
    set_plain_text if will_save_change_to_attribute?('text') || will_save_change_to_attribute?('text_markup')
  end

  def set_plain_text
    self.plain_text = ApplicationController.helpers.format_user_text_as_plain(text, text_markup).truncate_bytes(65_535)
  end

  before_destroy do
    discussion.destroy if first_comment?
  end

  after_soft_destroy do
    discussion.soft_destroy! if first_comment? && !discussion.soft_deleted?
  end

  after_commit do
    discussion.update_stats! unless discussion.destroyed? || discussion.soft_deleted?
  end

  after_destroy do
    Report.where(item: self).destroy_all
  end

  def send_notifications!
    users_received_notification = Set.new([poster])

    if first_comment? && discussion.script
      users_to_subscribe = discussion.script.users.where(subscribe_on_script_discussion: true) - [poster]
      users_to_subscribe.each do |user|
        DiscussionSubscription.create!(user:, discussion:)
      end
    end

    subscribed_users = UserNotificationService.notify_discussion_subscribed(self, ignored_users: users_received_notification) do |user|
      if first_comment?
        ForumMailer.comment_on_script(user, self).deliver_later
      else
        ForumMailer.comment_on_subscribed(user, self).deliver_later
      end
    end
    users_received_notification.merge(subscribed_users)

    mentioned_users = mentions
                      .where.not(user: users_received_notification)
                      .includes(:user)
                      .where(users: { notify_on_mention: true })
                      .map(&:user)
                      .uniq
    mentioned_users = mentioned_users.select(&:moderator?) if discussion_category.moderators_only?
    mentioned_users.each do |user|
      ForumMailer.comment_on_mentioned(user, self).deliver_later
    end
  end

  def notify_subscribers!; end

  def update_stats!
    update!(calculate_stats)
  end

  def assign_stats
    assign_attributes(calculate_stats)
  end

  def calculate_stats
    {
      first_comment: discussion.comments.order(:id).first == self,
    }
  end

  EDITABLE_PERIOD = 5.minutes

  def editable_by?(user)
    return false if new_record?
    return false unless user
    return false unless poster == user

    created_at >= EDITABLE_PERIOD.ago
  end

  def deletable_by?(user)
    return discussion.deletable_by?(user) if first_comment?

    editable_by?(user)
  end
end
