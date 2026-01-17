# Event Tracking System

This document explains how Fizzy tracks and processes significant actions throughout the application. The Event system serves as the central audit log and powers downstream features like activity timelines, notifications, webhooks, and system comments.

## Overview

Events are immutable records of significant actions that occur within Fizzy. When a user publishes a card, closes it, assigns someone, or leaves a comment, an Event is created. These events then cascade through several downstream systems:

```
User Action (close card, add comment, etc.)
         │
         ▼
    ┌─────────┐
    │  Event  │  ← Immutable audit record
    └─────────┘
         │
    ┌────┴────────────────────┬────────────────────┬─────────────────┐
    ▼                         ▼                    ▼                 ▼
Activity Timeline      Notifications          Webhooks        System Comments
(DayTimeline)         (Notifier)          (Dispatch/Deliver)  (SystemCommenter)
```

**Why Events?**

1. **Single source of truth** - All significant actions flow through one model
2. **Audit trail** - Complete history of what happened and who did it
3. **Loose coupling** - Downstream systems subscribe to events rather than being called directly
4. **Polymorphic flexibility** - Works with any "eventable" model (Cards, Comments)

## Event Model Structure

### Database Schema

```ruby
# From db/schema.rb (lines 279-294)
create_table "events", id: :uuid do |t|
  t.uuid "account_id", null: false
  t.string "action", null: false
  t.uuid "board_id", null: false
  t.datetime "created_at", null: false
  t.uuid "creator_id", null: false
  t.uuid "eventable_id", null: false
  t.string "eventable_type", null: false
  t.json "particulars", default: -> { "(json_object())" }
  t.datetime "updated_at", null: false

  t.index ["board_id", "action", "created_at"]  # For timeline queries
  t.index ["eventable_type", "eventable_id"]    # For polymorphic lookups
end
```

### Core Model

```ruby
# app/models/event.rb
class Event < ApplicationRecord
  include Notifiable, Particulars, Promptable

  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User"
  belongs_to :eventable, polymorphic: true

  has_many :webhook_deliveries, class_name: "Webhook::Delivery", dependent: :delete_all

  scope :chronologically, -> { order created_at: :asc, id: :desc }
  scope :preloaded, -> { includes(:creator, :board, { eventable: [...] }) }

  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks

  delegate :card, to: :eventable

  def action
    super.inquiry  # Returns StringInquirer for .comment_created? style checks
  end
end
```

### Key Associations

| Association | Purpose |
|-------------|---------|
| `account` | Multi-tenancy - derived from board |
| `board` | The board where the action occurred |
| `creator` | The user who performed the action |
| `eventable` | Polymorphic link to Card or Comment |
| `webhook_deliveries` | Outbound webhook delivery records |

### Event Actions

Events use a string `action` field with a consistent naming pattern: `{model}_{verb}`. The model prefix allows routing to the correct notifier class.

| Action | Eventable | Description |
|--------|-----------|-------------|
| `card_published` | Card | Card moved from draft to published |
| `card_closed` | Card | Card moved to "Done" |
| `card_reopened` | Card | Card reopened from closed state |
| `card_postponed` | Card | Card manually moved to "Not Now" |
| `card_auto_postponed` | Card | Card automatically postponed due to inactivity |
| `card_assigned` | Card | User(s) assigned to card |
| `card_unassigned` | Card | User(s) unassigned from card |
| `card_triaged` | Card | Card moved from triage to a column |
| `card_sent_back_to_triage` | Card | Card returned to triage |
| `card_title_changed` | Card | Card title was renamed |
| `card_board_changed` | Card | Card moved to different board |
| `card_collection_changed` | Card | Card moved to different collection |
| `comment_created` | Comment | New comment added to card |

## Creating Events

### The Eventable Concern

The `Eventable` concern provides the `track_event` method that all eventable models use:

```ruby
# app/models/concerns/eventable.rb
module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable, dependent: :destroy
  end

  def track_event(action, creator: Current.user, board: self.board, **particulars)
    if should_track_event?
      board.events.create!(
        action: "#{eventable_prefix}_#{action}",
        creator:,
        board:,
        eventable: self,
        particulars:
      )
    end
  end

  def event_was_created(event)
    # Override in including classes
  end

  private
    def should_track_event?
      true
    end

    def eventable_prefix
      self.class.name.demodulize.underscore  # "Card" -> "card"
    end
end
```

**Key design decisions:**

1. **Action naming** - Automatically prefixes with model name (`card_`, `comment_`)
2. **Creator defaulting** - Uses `Current.user` unless explicitly overridden
3. **Board association** - Events belong to boards for efficient timeline queries
4. **Conditional tracking** - `should_track_event?` allows models to skip events (e.g., draft cards)

### Card Event Tracking

Cards extend the base `Eventable` with additional behavior:

```ruby
# app/models/card/eventable.rb
module Card::Eventable
  extend ActiveSupport::Concern
  include ::Eventable

  included do
    before_create { self.last_active_at ||= created_at || Time.current }
    after_save :track_title_change, if: :saved_change_to_title?
  end

  def event_was_created(event)
    transaction do
      create_system_comment_for(event)
      touch_last_active_at unless was_just_published?
    end
  end

  private
    def should_track_event?
      published?  # Don't track events for draft cards
    end

    def track_title_change
      if title_before_last_save.present?
        track_event "title_changed", particulars: {
          old_title: title_before_last_save,
          new_title: title
        }
      end
    end

    def create_system_comment_for(event)
      SystemCommenter.new(self, event).comment
    end
end
```

### Comment Event Tracking

Comments have simpler event tracking:

```ruby
# app/models/comment/eventable.rb
module Comment::Eventable
  extend ActiveSupport::Concern
  include ::Eventable

  included do
    after_create_commit :track_creation
  end

  def event_was_created(event)
    card.touch_last_active_at  # Update parent card's activity
  end

  private
    def should_track_event?
      !creator.system?  # Don't track system-generated comments
    end

    def track_creation
      track_event("created", board: card.board, creator: creator)
    end
end
```

### Examples of Event Creation

Events are created from various card concerns:

```ruby
# app/models/card/closeable.rb
def close(user: Current.user)
  unless closed?
    transaction do
      not_now&.destroy
      create_closure! user: user
      track_event :closed, creator: user
    end
  end
end

# app/models/card/assignable.rb
def assign(user)
  assignment = assignments.create assignee: user, assigner: Current.user
  if assignment.persisted?
    watch_by user
    track_event :assigned, assignee_ids: [ user.id ]
  end
end

# app/models/card/triageable.rb
def triage_into(column)
  transaction do
    resume
    update! column: column
    track_event "triaged", particulars: { column: column.name }
  end
end

# app/models/card/statuses.rb
def publish
  transaction do
    self.created_at = Time.current
    published!
    track_event :published
  end
end
```

## The Particulars JSON Field

The `particulars` column stores action-specific metadata as JSON. This avoids needing separate columns for each event type's data.

### Structure

```ruby
# app/models/event/particulars.rb
module Event::Particulars
  extend ActiveSupport::Concern

  included do
    store_accessor :particulars, :assignee_ids
  end

  def assignees
    @assignees ||= User.where id: assignee_ids
  end
end
```

### Usage by Event Type

| Action | Particulars Keys | Example |
|--------|-----------------|---------|
| `card_assigned` | `assignee_ids` | `{ "assignee_ids": ["uuid1", "uuid2"] }` |
| `card_unassigned` | `assignee_ids` | `{ "assignee_ids": ["uuid1"] }` |
| `card_title_changed` | `old_title`, `new_title` | `{ "old_title": "Fix bug", "new_title": "Fix critical bug" }` |
| `card_board_changed` | `old_board`, `new_board` | `{ "old_board": "Backlog", "new_board": "Sprint 1" }` |
| `card_triaged` | `column` | `{ "column": "In Progress" }` |

### Accessing Particulars

The `Event::Description` class uses particulars to generate human-readable descriptions:

```ruby
# app/models/event/description.rb (lines 99-111)
def renamed_sentence(creator, card_title)
  old_title = event.particulars.dig("particulars", "old_title")
  %(#{creator} renamed #{card_title} (was: "#{h old_title}"))
end

def moved_sentence(creator, card_title)
  new_location = event.particulars.dig("particulars", "new_board") ||
                 event.particulars.dig("particulars", "new_collection")
  %(#{creator} moved #{card_title} to "#{h new_location}")
end
```

## Downstream Processing

### 1. Activity Timeline (DayTimeline)

The activity timeline shows a chronological feed of events grouped by day and category.

```ruby
# app/models/user/day_timeline.rb
class User::DayTimeline
  TIMELINEABLE_ACTIONS = %w[
    card_assigned card_unassigned card_published card_closed
    card_reopened card_collection_changed card_board_changed
    card_postponed card_auto_postponed card_triaged
    card_sent_back_to_triage comment_created
  ]

  def initialize(user, day, filter)
    @user, @day, @filter = user, day, filter
  end

  def events
    filtered_events.where(created_at: window).order(created_at: :desc)
  end

  # Events grouped into three columns
  def added_column
    build_column(:added, "Added", 1,
      events.where(action: %w[card_published card_reopened]))
  end

  def updated_column
    build_column(:updated, "Updated", 2,
      events.where.not(action: %w[card_published card_closed card_reopened]))
  end

  def closed_column
    build_column(:closed, "Done", 3,
      events.where(action: "card_closed"))
  end

  private
    def filtered_events
      events = Event.preloaded.where(board: boards).where(action: TIMELINEABLE_ACTIONS)
      events = events.where(creator_id: filter.creators.ids) if filter.creators.present?
      events
    end
end
```

Each column (`DayTimeline::Column`) groups events by hour:

```ruby
# app/models/user/day_timeline/column.rb
def events_by_hour
  limited_events.group_by { it.created_at.hour }
end
```

### 2. Notification System

Events trigger notifications to relevant users through a pipeline of classes.

#### Flow Diagram

```
Event (after_create_commit)
         │
         ▼
NotifyRecipientsJob.perform_later(event)
         │
         ▼
event.notify_recipients
         │
         ▼
Notifier.for(event)  →  CardEventNotifier or CommentEventNotifier
         │
         ▼
notifier.notify
         │
         ├──► Notification.create! (for each recipient)
         │           │
         │           ├──► broadcast_prepend_later_to (Turbo)
         │           ├──► bundle (if email bundling enabled)
         │           └──► PushNotificationJob.perform_later
         │
         └──► NotificationPusher.push (web push)
```

#### The Notifiable Concern

```ruby
# app/models/concerns/notifiable.rb
module Notifiable
  extend ActiveSupport::Concern

  included do
    has_many :notifications, as: :source, dependent: :destroy
    after_create_commit :notify_recipients_later
  end

  def notify_recipients
    Notifier.for(self)&.notify
  end

  private
    def notify_recipients_later
      NotifyRecipientsJob.perform_later self
    end
end
```

#### The Notifier Pattern

`Notifier` is a factory that creates the appropriate notifier subclass:

```ruby
# app/models/notifier.rb
class Notifier
  class << self
    def for(source)
      case source
      when Event
        "Notifier::#{source.eventable.class}EventNotifier".safe_constantize&.new(source)
      when Mention
        MentionNotifier.new(source)
      end
    end
  end

  def notify
    if should_notify?
      recipients.sort_by(&:id).map do |recipient|
        Notification.create! user: recipient, source: source, creator: creator
      end
    end
  end

  private
    def should_notify?
      !creator.system?  # Don't notify for system-generated events
    end
end
```

#### Recipient Selection

Different event types notify different users:

```ruby
# app/models/notifier/card_event_notifier.rb
class Notifier::CardEventNotifier < Notifier
  private
    def recipients
      case source.action
      when "card_assigned"
        source.assignees.excluding(creator)
      when "card_published"
        board.watchers.without(creator, *card.mentionees).including(*card.assignees).uniq
      when "comment_created"
        card.watchers.without(creator, *source.eventable.mentionees)
      else
        board.watchers.without(creator)
      end
    end
end
```

#### Email Bundling

Rather than sending immediate emails, notifications can be bundled:

```ruby
# app/models/notification.rb
after_create :bundle

def bundle
  user.bundle(self) if user.settings.bundling_emails?
end

# app/models/notification/bundle.rb
class Notification::Bundle < ApplicationRecord
  def deliver
    user.in_time_zone do
      Current.with_account(user.account) do
        processing!
        Notification::BundleMailer.notification(self).deliver if deliverable?
        delivered!
      end
    end
  end
end
```

Bundled notifications are delivered every 30 minutes via a recurring job:

```yaml
# config/recurring.yml
deliver_bundled_notifications:
  command: "Notification::Bundle.deliver_all_later"
  schedule: every 30 minutes
```

#### Push Notifications

Web push notifications are handled asynchronously:

```ruby
# app/models/concerns/push_notifiable.rb
module PushNotifiable
  included do
    after_create_commit :push_notification_later
  end

  private
    def push_notification_later
      PushNotificationJob.perform_later(self)
    end
end

# app/models/notification_pusher.rb
class NotificationPusher
  def push
    return unless should_push?
    build_payload.tap { |payload| push_to_user(payload) }
  end

  private
    def should_push?
      notification.user.push_subscriptions.any? &&
        !notification.creator.system? &&
        notification.user.active? &&
        notification.account.active?
    end
end
```

### 3. Webhook System

Events can trigger outbound webhooks to external services.

#### Dispatch Flow

```
Event (after_create_commit)
         │
         ▼
Event::WebhookDispatchJob.perform_later(event)
         │
         ▼
Webhook.active.triggered_by(event).find_each
         │
         ▼
webhook.trigger(event)
         │
         ▼
deliveries.create!(event: event)
         │
         ▼
Webhook::DeliveryJob.perform_later(delivery)
         │
         ▼
delivery.deliver
         │
         ▼
HTTP POST to webhook.url
         │
         ▼
delinquency_tracker.record_delivery_of(delivery)
```

#### Webhook Configuration

```ruby
# app/models/webhook.rb
class Webhook < ApplicationRecord
  PERMITTED_ACTIONS = %w[
    card_assigned card_closed card_postponed card_auto_postponed
    card_board_changed card_published card_reopened
    card_sent_back_to_triage card_triaged card_unassigned
    comment_created
  ]

  belongs_to :board
  has_many :deliveries, dependent: :delete_all
  has_one :delinquency_tracker, dependent: :delete

  serialize :subscribed_actions, type: Array, coder: JSON
end
```

#### Triggerable Concern

```ruby
# app/models/webhook/triggerable.rb
module Webhook::Triggerable
  included do
    scope :triggered_by, ->(event) {
      where(board: event.board).triggered_by_action(event.action)
    }
    scope :triggered_by_action, ->(action) {
      where("subscribed_actions LIKE ?", "%\"#{action}\"%")
    }
  end

  def trigger(event)
    deliveries.create!(event: event) unless account.cancelled?
  end
end
```

#### Delivery

```ruby
# app/models/webhook/delivery.rb
class Webhook::Delivery < ApplicationRecord
  ENDPOINT_TIMEOUT = 7.seconds
  MAX_RESPONSE_SIZE = 100.kilobytes

  def deliver
    in_progress!
    self.request[:headers] = headers
    self.response = perform_request
    self.state = :completed
    save!
    webhook.delinquency_tracker.record_delivery_of(self)
  rescue
    errored!
    raise
  end

  private
    def headers
      {
        "User-Agent" => "fizzy/1.0.0 Webhook",
        "Content-Type" => content_type,
        "X-Webhook-Signature" => signature,
        "X-Webhook-Timestamp" => event.created_at.utc.iso8601
      }
    end

    def signature
      OpenSSL::HMAC.hexdigest("SHA256", webhook.signing_secret, payload)
    end
end
```

#### Delinquency Tracking

Webhooks are automatically disabled after repeated failures:

```ruby
# app/models/webhook/delinquency_tracker.rb
class Webhook::DelinquencyTracker < ApplicationRecord
  DELINQUENCY_THRESHOLD = 10
  DELINQUENCY_DURATION = 1.hour

  def record_delivery_of(delivery)
    if delivery.succeeded?
      reset
    else
      mark_first_failure_time if consecutive_failures_count.zero?
      increment!(:consecutive_failures_count, touch: true)
      webhook.deactivate if delinquent?
    end
  end

  private
    def delinquent?
      failing_for_too_long? && too_many_consecutive_failures?
    end

    def failing_for_too_long?
      first_failure_at&.before?(DELINQUENCY_DURATION.ago)
    end

    def too_many_consecutive_failures?
      consecutive_failures_count >= DELINQUENCY_THRESHOLD
    end
end
```

#### Payload Formats

Webhooks support multiple output formats:

```ruby
# app/models/webhook/delivery.rb
def content_type
  if webhook.for_campfire?
    "text/html"
  elsif webhook.for_basecamp?
    "application/x-www-form-urlencoded"
  else
    "application/json"
  end
end
```

JSON payload template:

```ruby
# app/views/webhooks/event.json.jbuilder
json.(@event, :id, :action)
json.created_at @event.created_at.utc

json.eventable do
  case @event.eventable
  when Card then json.partial! "cards/card", card: @event.eventable
  when Comment then json.partial! "cards/comments/comment", comment: @event.eventable
  end
end

json.board @event.board, partial: "boards/board", as: :board
json.creator @event.creator, partial: "users/user", as: :user
```

### 4. System Comments

When certain events occur on cards, a system comment is automatically created to show the change in the card's comment thread.

```ruby
# app/models/card/eventable/system_commenter.rb
class Card::Eventable::SystemCommenter
  def initialize(card, event)
    @card, @event = card, event
  end

  def comment
    return unless comment_body.present?
    card.comments.create! creator: card.account.system_user,
                          body: comment_body,
                          created_at: event.created_at
  end

  private
    def comment_body
      case event.action
      when "card_assigned"
        "#{creator_name} <strong>assigned</strong> this to #{assignee_names}."
      when "card_closed"
        "<strong>Moved</strong> to \"Done\" by #{creator_name}"
      when "card_reopened"
        "<strong>Reopened</strong> by #{creator_name}"
      when "card_postponed"
        "#{creator_name} <strong>moved</strong> this to \"Not Now\""
      when "card_auto_postponed"
        "<strong>Moved</strong> to \"Not Now\" due to inactivity"
      when "card_title_changed"
        "#{creator_name} <strong>changed the title</strong> from \"#{old_title}\" to \"#{new_title}\"."
      when "card_board_changed"
        "#{creator_name} <strong>moved</strong> this from \"#{old_board}\" to \"#{new_board}\"."
      when "card_triaged"
        "#{creator_name} <strong>moved</strong> this to \"#{column}\""
      when "card_sent_back_to_triage"
        "#{creator_name} <strong>moved</strong> this back to \"Maybe?\""
      end
    end
end
```

**Key insight:** System comments are created by the account's `system_user`, making them visually distinct in the UI. They are filtered out of notification calculations (`should_track_event?` returns `false` for system users).

## Event Flow Diagram

Here is the complete lifecycle of an event from user action to all downstream effects:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           USER ACTION                                          │
│                    (e.g., card.close(user: Current.user))                      │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                         track_event(:closed)                                   │
│                                                                                │
│  board.events.create!(                                                         │
│    action: "card_closed",                                                      │
│    creator: user,                                                              │
│    eventable: card,                                                            │
│    particulars: {}                                                             │
│  )                                                                             │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                 ┌──────────────────┼──────────────────┐
                 │                  │                  │
                 ▼                  ▼                  ▼
        after_create       after_create_commit  after_create_commit
                 │                  │                  │
                 ▼                  ▼                  ▼
┌────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│  event_was_created │  │ notify_recipients_  │  │  dispatch_webhooks  │
│       (sync)       │  │      later          │  │                     │
└────────────────────┘  └─────────────────────┘  └─────────────────────┘
         │                       │                        │
         ▼                       ▼                        ▼
┌────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│ SystemCommenter    │  │ NotifyRecipientsJob │  │ WebhookDispatchJob  │
│   .comment         │  │    (async)          │  │      (async)        │
└────────────────────┘  └─────────────────────┘  └─────────────────────┘
         │                       │                        │
         ▼                       ▼                        │
┌────────────────────┐  ┌─────────────────────┐          │
│ Comment.create!    │  │ Notifier.for(event) │          │
│ (system user)      │  │   .notify           │          │
└────────────────────┘  └─────────────────────┘          │
                                 │                        │
                    ┌────────────┴────────────┐          │
                    ▼                         ▼          ▼
         ┌─────────────────┐      ┌──────────────────────────────┐
         │ Notification    │      │ Webhook.triggered_by(event)  │
         │   .create!      │      │   .each { |w| w.trigger }    │
         │ (per recipient) │      └──────────────────────────────┘
         └─────────────────┘                  │
                    │                         ▼
         ┌─────────┴─────────┐    ┌──────────────────────────────┐
         ▼                   ▼    │   Webhook::Delivery.create!  │
┌─────────────────┐  ┌────────────┐ └──────────────────────────────┘
│ Turbo Broadcast │  │   Bundle   │              │
│ (real-time UI)  │  │ (optional) │              ▼
└─────────────────┘  └────────────┘  ┌──────────────────────────────┐
                            │        │   Webhook::DeliveryJob       │
                            ▼        │      delivery.deliver        │
                     ┌────────────┐  └──────────────────────────────┘
                     │ BundleMailer│              │
                     │ (batched)  │              ▼
                     └────────────┘  ┌──────────────────────────────┐
                                     │    HTTP POST to endpoint     │
         ┌─────────────────┐         │    + delinquency tracking    │
         │PushNotificationJob│       └──────────────────────────────┘
         │  (web push)     │
         └─────────────────┘
```

## Key Design Decisions

### 1. Events are Immutable

Once created, events are never modified. This ensures:
- Reliable audit trail
- Safe for webhook replay/retry
- Consistent notification state

### 2. Polymorphic Eventables

Using polymorphic associations (`eventable_type`, `eventable_id`) allows:
- Single events table for all event types
- Unified query patterns across Cards and Comments
- Easy addition of new eventable types

### 3. Action String Convention

The `{model}_{verb}` naming convention enables:
- Factory-based notifier selection (`"Notifier::#{eventable.class}EventNotifier"`)
- Clear webhook subscription patterns
- Readable audit logs

### 4. Particulars as JSON

Storing action-specific data in JSON:
- Avoids schema changes for new event types
- Keeps the events table simple
- Allows flexible, type-specific metadata

### 5. Asynchronous Downstream Processing

All downstream effects run in background jobs:
- `NotifyRecipientsJob` for notifications
- `PushNotificationJob` for web push
- `Event::WebhookDispatchJob` for webhook dispatch
- `Webhook::DeliveryJob` for HTTP delivery

This ensures:
- Fast user-facing responses
- Resilience to external service failures
- Retry capability for transient errors

### 6. Board-Scoped Events

Events belong to boards (not just accounts):
- Efficient timeline queries scoped to accessible boards
- Natural grouping for board-level activity feeds
- Enables board-level webhook subscriptions

### 7. Creator-Based Exclusions

Notifications exclude the event creator:
- Users don't get notified of their own actions
- System users don't trigger notifications
- Mentioned users are excluded from broadcast notifications (they get @mention notifications instead)

## Files Reference

| File | Purpose |
|------|---------|
| `app/models/event.rb` | Core Event model |
| `app/models/concerns/eventable.rb` | Base concern for eventable models |
| `app/models/card/eventable.rb` | Card-specific event behavior |
| `app/models/comment/eventable.rb` | Comment-specific event behavior |
| `app/models/event/particulars.rb` | JSON particulars accessor |
| `app/models/event/description.rb` | Human-readable event descriptions |
| `app/models/concerns/notifiable.rb` | Notification triggering concern |
| `app/models/notifier.rb` | Notification factory and base class |
| `app/models/notifier/card_event_notifier.rb` | Card event recipient selection |
| `app/models/notifier/comment_event_notifier.rb` | Comment event recipient selection |
| `app/models/notification.rb` | Notification record |
| `app/models/notification/bundle.rb` | Email bundling |
| `app/models/notification_pusher.rb` | Web push notification delivery |
| `app/models/webhook.rb` | Webhook configuration |
| `app/models/webhook/triggerable.rb` | Event-to-webhook matching |
| `app/models/webhook/delivery.rb` | Webhook HTTP delivery |
| `app/models/webhook/delinquency_tracker.rb` | Failure tracking for auto-disable |
| `app/models/card/eventable/system_commenter.rb` | System comment generation |
| `app/models/user/day_timeline.rb` | Activity timeline model |
| `app/models/user/day_timeline/column.rb` | Timeline column grouping |
| `app/jobs/notify_recipients_job.rb` | Async notification job |
| `app/jobs/push_notification_job.rb` | Async push notification job |
| `app/jobs/event/webhook_dispatch_job.rb` | Async webhook dispatch job |
| `app/jobs/webhook/delivery_job.rb` | Async webhook delivery job |
| `app/views/webhooks/event.json.jbuilder` | JSON webhook payload template |
| `config/recurring.yml` | Scheduled jobs (bundled notifications) |
