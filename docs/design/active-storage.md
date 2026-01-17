# Active Storage Customizations

Fizzy extends Rails Active Storage with multi-tenant isolation, authorization, storage usage tracking, and several performance optimizations. This document details each customization, why it exists, and how the pieces integrate.

## Table of Contents

1. [Overview](#overview)
2. [Multi-Tenant Data Isolation](#multi-tenant-data-isolation)
3. [Authorization](#authorization)
4. [Storage Usage Tracking (Ledger System)](#storage-usage-tracking-ledger-system)
5. [Blob Reuse Prevention](#blob-reuse-prevention)
6. [Purge on Last Attachment](#purge-on-last-attachment)
7. [ActionText Integration](#actiontext-integration)
8. [Performance Optimizations](#performance-optimizations)
9. [Direct Upload Support](#direct-upload-support)
10. [Key Files Reference](#key-files-reference)

---

## Overview

Fizzy's Active Storage customizations solve several interconnected problems:

| Problem | Solution |
|---------|----------|
| Blobs must belong to tenants | Add `account_id` to all framework tables |
| Users should only access their own files | Authorization checks on blob/attachment access |
| Track storage usage for quotas | Event-sourced ledger system |
| Prevent quota manipulation via blob reuse | Validation blocking tracked blob reuse |
| ActionText embeds need blob sharing | Allow embeds to reuse blobs, purge only when last attachment removed |
| Turbo broadcasts during analysis cause page refreshes | Suppress broadcasts in AnalyzeJob |
| Slow uploads timeout with Cloudflare | Extended direct upload URL expiry |

---

## Multi-Tenant Data Isolation

### The Problem

Active Storage's built-in tables (`active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records`) have no concept of tenancy. In a multi-tenant app, blobs from one account could theoretically be accessed by another.

### The Solution

Fizzy adds `account_id` columns to all Active Storage (and ActionText) framework tables and injects `belongs_to :account` associations at runtime.

**Schema additions** (see `db/schema.rb`):
```ruby
create_table "active_storage_blobs" do |t|
  t.uuid "account_id", null: false
  # ... standard columns
end

create_table "active_storage_attachments" do |t|
  t.uuid "account_id", null: false
  # ...
end

create_table "active_storage_variant_records" do |t|
  t.uuid "account_id", null: false
  # ...
end

create_table "action_text_rich_texts" do |t|
  t.uuid "account_id", null: false
  # ...
end
```

**Association injection** (`config/initializers/uuid_framework_models.rb`):
```ruby
Rails.application.config.to_prepare do
  ActionText::RichText.belongs_to :account, default: -> { record.account }
  ActiveStorage::Attachment.belongs_to :account, default: -> { record.account }
  ActiveStorage::Blob.belongs_to :account, default: -> { Current.account }
  ActiveStorage::VariantRecord.belongs_to :account, default: -> { blob.account }
end
```

### How Account IDs Propagate

The `default:` lambdas create a cascade:

1. **Blob** gets `account_id` from `Current.account` (set by request middleware)
2. **Attachment** gets `account_id` from the record it's attached to
3. **VariantRecord** gets `account_id` from its parent blob
4. **RichText** gets `account_id` from the record it belongs to

This ensures all storage-related records inherit the correct tenant without explicit assignment.

### Cross-Account Validation

To prevent attaching a blob from one account to a record in another, a validation in `active_storage_no_reuse.rb` enforces:

```ruby
def blob_account_matches_record
  if record&.try(:account).present? && !whitelisted_for_cross_account?
    unless blob&.account_id == record.account.id
      errors.add(:blob_id, "blob account must match record account")
    end
  end
end
```

**Exception**: Global/unaccounted attachments (like Identity avatars) bypass this check because their records don't have an `account` association.

---

## Authorization

### The Problem

Active Storage serves files via its own controllers (`ActiveStorage::Blobs::RedirectController`, etc.). Without customization, any user with a blob URL could access any file.

### The Solution

Fizzy adds authorization checks to all Active Storage serving controllers.

**Implementation** (`lib/rails_ext/active_storage_authorization.rb`):

```ruby
module ActiveStorage::Authorize
  extend ActiveSupport::Concern
  include Authentication

  included do
    skip_before_action :require_authentication
    before_action :require_authentication, :ensure_accessible,
                  unless: :publicly_accessible_blob?
  end

  private
    def publicly_accessible_blob?
      @blob.publicly_accessible?
    end

    def ensure_accessible
      unless @blob.accessible_to?(Current.user)
        head :forbidden
      end
    end
end

ActiveStorage::Blobs::RedirectController.include ActiveStorage::Authorize
ActiveStorage::Blobs::ProxyController.include ActiveStorage::Authorize
ActiveStorage::Representations::RedirectController.include ActiveStorage::Authorize
ActiveStorage::Representations::ProxyController.include ActiveStorage::Authorize
```

### Accessibility Chain

The `accessible_to?` and `publicly_accessible?` methods chain through the object hierarchy:

```
Blob
  └── checks all Attachments
       └── delegates to Record (Card, Comment, etc.)
            └── delegates to Board (for access control)
```

**Blob** (`lib/rails_ext/active_storage_authorization.rb`):
```ruby
def accessible_to?(user)
  attachments.includes(:record).any? { |a| a.accessible_to?(user) } || attachments.none?
end

def publicly_accessible?
  attachments.includes(:record).any? { |a| a.publicly_accessible? }
end
```

**Attachment**:
```ruby
def accessible_to?(user)
  record.try(:accessible_to?, user)
end
```

**Card** delegates to Board, Board checks Access records or "all access" status.

**Public boards**: When a board is published, its cards (and their attachments) become publicly accessible without authentication.

---

## Storage Usage Tracking (Ledger System)

### The Problem

Fizzy needs to track storage usage per account and per board for quota enforcement and billing. Directly summing blob sizes on every request would be expensive.

### The Solution

An event-sourced ledger system that records attach/detach events, with periodic materialization into snapshots.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Storage Tracking Flow                         │
└─────────────────────────────────────────────────────────────────┘

  Attachment Created
         │
         ▼
  ┌──────────────────┐
  │ AttachmentTracking│  after_create_commit :record_storage_attach
  │ concern           │
  └──────────────────┘
         │
         ▼
  ┌──────────────────┐
  │ Storage::Entry    │  delta: +byte_size, operation: "attach"
  │ (ledger entry)    │
  └──────────────────┘
         │
         ├──────────────────────────────────────┐
         ▼                                      ▼
  ┌──────────────────┐                  ┌──────────────────┐
  │ Account          │                  │ Board            │
  │ materialize_storage_later           │ materialize_storage_later
  └──────────────────┘                  └──────────────────┘
         │                                      │
         ▼                                      ▼
  ┌──────────────────┐                  ┌──────────────────┐
  │ Storage::Total    │                  │ Storage::Total    │
  │ (Account owner)   │                  │ (Board owner)     │
  │ bytes_stored: sum │                  │ bytes_stored: sum │
  └──────────────────┘                  └──────────────────┘
```

### Key Components

**Storage::Entry** (`app/models/storage/entry.rb`) - The ledger record:
```ruby
class Storage::Entry < ApplicationRecord
  belongs_to :account
  belongs_to :board, optional: true
  belongs_to :recordable, polymorphic: true, optional: true

  def self.record(delta:, operation:, account:, board: nil, recordable: nil, blob: nil)
    return if delta.zero?
    return if account.destroyed?

    entry = create!(
      account_id: account.id,
      board_id: board&.id,
      recordable_type: recordable&.class&.name,
      recordable_id: recordable&.id,
      blob_id: blob&.id,
      delta: delta,
      operation: operation,
      user_id: Current.user&.id,
      request_id: Current.request_id
    )

    account.materialize_storage_later
    board&.materialize_storage_later unless board&.destroyed?

    entry
  end
end
```

**Storage::AttachmentTracking** (`app/models/storage/attachment_tracking.rb`) - Mixed into ActiveStorage::Attachment:
```ruby
module Storage::AttachmentTracking
  included do
    before_destroy :snapshot_storage_context
    after_create_commit :record_storage_attach
    after_destroy_commit :record_storage_detach
  end

  def record_storage_attach
    return unless storage_tracked_record
    Storage::Entry.record(
      account: storage_tracked_record.account,
      board: storage_tracked_record.board_for_storage_tracking,
      recordable: storage_tracked_record,
      blob: blob,
      delta: blob.byte_size,
      operation: "attach"
    )
  end
end
```

**Storage::Tracked** (`app/models/concerns/storage/tracked.rb`) - Mixed into models that should track storage (Card, Comment):
```ruby
module Storage::Tracked
  def storage_tracked_record
    self
  end

  def board_for_storage_tracking
    board
  end
end
```

**Storage::Totaled** (`app/models/concerns/storage/totaled.rb`) - Mixed into Account and Board for materialized snapshots:
```ruby
module Storage::Totaled
  def bytes_used
    storage_total&.bytes_stored || 0  # Fast: uses snapshot
  end

  def bytes_used_exact
    create_or_find_storage_total.current_usage  # Exact: snapshot + pending
  end

  def materialize_storage
    # Sums pending entries and updates snapshot
  end
end
```

### Tracked Record Types

Only specific record types participate in storage tracking:

```ruby
# app/models/storage.rb
module Storage
  TRACKED_RECORD_TYPES = %w[Card ActionText::RichText].freeze
end
```

Avatars, exports, and other non-core attachments are intentionally excluded from quota tracking.

### Board Transfers

When a card moves between boards, the storage tracking records the transfer:

```ruby
def track_board_transfer
  # Debit old board
  Storage::Entry.record(delta: -bytes, operation: "transfer_out", board: old_board)
  # Credit new board
  Storage::Entry.record(delta: bytes, operation: "transfer_in", board: new_board)
end
```

---

## Blob Reuse Prevention

### The Problem

Active Storage allows the same blob to be attached to multiple records. In a quota-tracked system, this could allow:
1. Cross-tenant data access (blob from Account A attached to Account B)
2. Quota manipulation (attach same blob multiple times, detach once to "recover" space)

### The Solution

Validation in `active_storage_no_reuse.rb` prevents blob reuse in tracked contexts:

```ruby
def no_tracked_blob_reuse
  tracked_record = record&.try(:storage_tracked_record)

  if tracked_record.present? &&
      !whitelisted_for_cross_account? &&
      !(record_type == "ActionText::RichText" && name == "embeds")

    existing = ActiveStorage::Attachment
      .where(blob_id: blob_id)
      .where(record_type: Storage::TRACKED_RECORD_TYPES)
      .where.not(id: id)
      .exists?

    if existing
      errors.add(:blob_id, "cannot reuse blob in tracked storage context")
    end
  end
end
```

### Exceptions

1. **ActionText embeds**: Allowed to reuse blobs to support copy/paste of rich text content
2. **Template account blobs**: Can be reused cross-tenant (configurable via `Storage::TEMPLATE_ACCOUNT_ID`)
3. **Untracked contexts**: Avatars, exports, etc. don't block or check for reuse

---

## Purge on Last Attachment

### The Problem

Active Storage's default `purge` and `purge_later` methods use `delete` internally, skipping callbacks. Fizzy needs callbacks to:
1. Record storage ledger detach events
2. Only purge blobs when the last attachment is removed (for ActionText embed sharing)

### The Solution

Override purge methods to use `destroy` and check for remaining attachments:

```ruby
# config/initializers/active_storage_purge_on_last_attachment.rb
module ActiveStorage::PurgeOnLastAttachment
  def purge
    @purge_mode = :purge
    destroy
    purge_blob_if_last(:purge) if destroyed?
  ensure
    @purge_mode = nil
  end

  def purge_later
    @purge_mode = :purge_later
    destroy
    purge_blob_if_last(:purge_later) if destroyed?
  ensure
    @purge_mode = nil
  end

  private
    def purge_blob_if_last(mode)
      if blob && !blob.attachments.exists?
        mode == :purge ? blob.purge : blob.purge_later
      end
    end
end
```

This ensures:
- Attachment callbacks fire (for ledger tracking)
- Blob is only purged when no attachments remain (for shared embeds)

---

## ActionText Integration

### The Problem

ActionText rich text content can include embedded images. These need:
1. Proper tenant isolation
2. Authorization that follows the parent record
3. Image variants for display

### The Solution

**RichText extensions** (`config/initializers/action_text.rb`):

```ruby
module ActionText::Extensions::RichText
  included do
    # Define variants for embedded images
    has_many_attached :embeds do |attachable|
      Attachments::VARIANTS.each do |variant_name, variant_options|
        attachable.variant variant_name, **variant_options, process: :immediately
      end
    end
  end

  # Delegate storage tracking to parent record
  def storage_tracked_record
    record.try(:storage_tracked_record)
  end

  # Delegate authorization to parent record
  def accessible_to?(user)
    record.try(:accessible_to?, user) || record.try(:publicly_accessible?)
  end
end
```

**Image variants** (`app/models/concerns/attachments.rb`):
```ruby
module Attachments
  VARIANTS = {
    small: { loader: { n: -1 }, resize_to_limit: [800, 600] },
    large: { loader: { n: -1 }, resize_to_limit: [1024, 768] }
  }
end
```

The `loader: { n: -1 }` setting preserves animated GIF frames during variant processing.

**Relative URLs for portability** (`config/initializers/active_storage.rb`):
```ruby
def to_rich_text_attributes(*)
  super.merge url: Rails.application.routes.url_helpers.polymorphic_url(self, only_path: true)
end
```

This ensures `<action-text-attachment>` elements use relative paths, allowing content to work across different hostnames (beta environments, etc.).

---

## Performance Optimizations

### Suppress Turbo Broadcasts During Analysis

**Problem**: When Active Storage analyzes a blob (extracting dimensions, etc.), it touches the attachment record. This triggers Turbo broadcasts, causing unnecessary page refreshes.

**Solution** (`lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb`):
```ruby
module ActiveStorageAnalyzeJobSuppressBroadcasts
  def perform(blob)
    Board.suppressing_turbo_broadcasts do
      Card.suppressing_turbo_broadcasts do
        super
      end
    end
  end
end

ActiveStorage::AnalyzeJob.prepend ActiveStorageAnalyzeJobSuppressBroadcasts
```

### Extended Direct Upload URL Expiry

**Problem**: Cloudflare buffers slow client uploads before forwarding them. A 10GB upload at 0.5Mbps could take longer than the default URL expiry.

**Solution** (`lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb`):
```ruby
module ActiveStorage
  mattr_accessor :service_urls_for_direct_uploads_expire_in, default: 48.hours
end

module ActiveStorageBlobServiceUrlForDirectUploadExpiry
  def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_for_direct_uploads_expire_in)
    super
  end
end
```

48 hours covers a 10GB upload at 0.5Mbps with margin.

### Shared Connection Pool for Active Storage

**Problem**: When `ActiveStorage::Record` uses `connects_to` for replica configuration, it creates a separate connection pool from `ApplicationRecord`. This causes non-deterministic `after_commit` callback ordering, breaking `process: :immediately` variants.

**Solution** (`config/initializers/active_storage.rb`):
```ruby
ActiveSupport.on_load(:active_storage_record) do
  configure_replica_connections
end
```

By calling the same `configure_replica_connections` method that `ApplicationRecord` uses, Active Storage shares the same connection pool, ensuring deterministic callback ordering.

### Disk Service Caching

**Solution** (`config/initializers/active_storage.rb`):
```ruby
ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    expires_in 5.minutes, public: true
  end
end
```

Adds HTTP caching headers to Disk Service responses in development.

---

## Direct Upload Support

### Multi-Tenant URL Generation

**Problem**: Active Storage's direct upload URLs need to include the account slug (`/1234567/...`) for proper routing.

**Solution** (`config/initializers/active_storage.rb`):
```ruby
module ActiveStorageControllerExtensions
  included do
    before_action do
      ActiveStorage::Current.url_options = {
        protocol: request.protocol,
        host: request.host,
        port: request.port,
        script_name: request.script_name  # Includes account slug
      }
    end
  end
end

ActiveStorage::BaseController.include ActiveStorageControllerExtensions
```

### API Authentication for Direct Uploads

**Problem**: API clients need to authenticate direct uploads via bearer tokens instead of cookies.

**Solution**:
```ruby
module ActiveStorageDirectUploadsControllerExtensions
  included do
    include Authentication
    include Authorization
    skip_forgery_protection if: :authenticate_by_bearer_token
  end
end

ActiveStorage::DirectUploadsController.include ActiveStorageDirectUploadsControllerExtensions
```

---

## Key Files Reference

### Initializers

| File | Purpose |
|------|---------|
| `config/initializers/active_storage.rb` | URL options, caching, connection pool, controller extensions |
| `config/initializers/active_storage_no_reuse.rb` | Blob reuse prevention validations |
| `config/initializers/active_storage_purge_on_last_attachment.rb` | Callback-aware purge methods |
| `config/initializers/uuid_framework_models.rb` | Account associations for framework models |
| `config/initializers/action_text.rb` | RichText extensions and variants |

### Library Extensions

| File | Purpose |
|------|---------|
| `lib/rails_ext/active_storage_authorization.rb` | Authorization for blob serving controllers |
| `lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb` | Suppress Turbo during analysis |
| `lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb` | Extended upload URL expiry |

### Models

| File | Purpose |
|------|---------|
| `app/models/storage.rb` | Module constants (TRACKED_RECORD_TYPES, TEMPLATE_ACCOUNT_ID) |
| `app/models/storage/entry.rb` | Ledger entry record |
| `app/models/storage/total.rb` | Materialized storage snapshot |
| `app/models/storage/attachment_tracking.rb` | Attachment callbacks for ledger |
| `app/models/concerns/storage/tracked.rb` | Mixin for tracked records |
| `app/models/concerns/storage/totaled.rb` | Mixin for accounts/boards with totals |
| `app/models/concerns/attachments.rb` | Variant definitions and helpers |

### Jobs

| File | Purpose |
|------|---------|
| `app/jobs/storage/materialize_job.rb` | Async materialization of storage totals |

---

## Summary

Fizzy's Active Storage customizations form an integrated system:

1. **Multi-tenancy**: All framework tables have `account_id`, enforced by validation
2. **Authorization**: Blob access checks chain through attachments to parent records
3. **Storage tracking**: Event-sourced ledger with materialized snapshots for fast reads
4. **Blob integrity**: Reuse prevention except where explicitly allowed (embeds, templates)
5. **ActionText integration**: Shared authorization, tracking delegation, variant processing
6. **Performance**: Broadcast suppression, extended upload URLs, shared connection pools

These customizations enable Fizzy to offer secure, quota-tracked file storage in a multi-tenant SaaS environment while maintaining the developer ergonomics of standard Active Storage.
