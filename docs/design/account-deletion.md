# Account Deletion System

This document describes how Fizzy handles account deletion, including the soft-delete mechanism, grace period, and permanent data destruction.

## Table of Contents

1. [Overview](#overview)
2. [Design Philosophy](#design-philosophy)
3. [Deletion Flow](#deletion-flow)
4. [Core Components](#core-components)
5. [Access Control During Cancellation](#access-control-during-cancellation)
6. [SaaS Billing Integration](#saas-billing-integration)
7. [Reactivation](#reactivation)
8. [File Reference Index](#file-reference-index)

---

## Overview

Fizzy implements a **two-phase account deletion** system:

1. **Cancellation (Soft Delete)**: Account is marked as cancelled, users lose access immediately
2. **Incineration (Hard Delete)**: After a 30-day grace period, all data is permanently destroyed

This approach provides:
- Immediate effect (users cannot access cancelled accounts)
- Protection against accidental deletion (30-day recovery window)
- Clean data destruction (cascading deletes remove all associated records)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Account Deletion Timeline                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Day 0                        Day 30                                         │
│    │                            │                                            │
│    ▼                            ▼                                            │
│  ┌────────────┐              ┌─────────────┐                                │
│  │ Cancelled  │─────────────▶│ Incinerated │                                │
│  └────────────┘              └─────────────┘                                │
│        │                           │                                         │
│        │ - Users blocked           │ - Account destroyed                     │
│        │ - Email sent              │ - All data deleted                      │
│        │ - Subscription paused     │ - Subscription cancelled                │
│        │ - Can be reactivated      │ - Irreversible                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Design Philosophy

### Soft Delete via Separate Record

Rather than adding a `cancelled_at` column to the `accounts` table, Fizzy uses a separate `account_cancellations` table. This provides:

- **Clean separation of concerns**: The `Account` model stays focused on account data
- **Audit trail**: The cancellation record tracks who initiated the deletion and when
- **Simple queries**: `Account.active` scope uses `where.missing(:cancellation)`
- **Easy reactivation**: Simply destroy the cancellation record

### Callback-Based Extensions

The system uses Rails callbacks (`define_callbacks :cancel`, `:reactivate`, `:incinerate`) to allow other concerns to hook into the deletion lifecycle. This is used by the SaaS billing module to manage subscription state.

### Single-Tenant Mode Protection

In single-tenant deployments, account deletion is disabled. The `cancellable?` method checks `Account.accepting_signups?`, which returns `false` when:
- Multi-tenant mode is disabled (`Account.multi_tenant == false`)
- AND at least one account exists

This prevents users from accidentally deleting the only account in a self-hosted installation.

---

## Deletion Flow

### Step 1: User Initiates Deletion (UI)

**File:** `/app/views/account/settings/_cancellation.html.erb`

The delete button appears in account settings only when:
- `Current.account.cancellable?` is true (multi-tenant mode)
- `Current.user.owner?` is true

```erb
<% if Current.account.cancellable? && Current.user.owner? %>
  <!-- Confirmation dialog with warnings -->
  <dialog>
    <ul>
      <li>All users, including you, will lose access</li>
      <% if Current.account.try(:active_subscription) %>
        <li>Your subscription will be canceled</li>
      <% end %>
      <li>After 30 days your data will be permanently deleted</li>
    </ul>
    <!-- Delete button posts to account_cancellation_path -->
  </dialog>
<% end %>
```

### Step 2: Controller Handles Request

**File:** `/app/controllers/account/cancellations_controller.rb`

```ruby
class Account::CancellationsController < ApplicationController
  before_action :ensure_owner

  def create
    Current.account.cancel
    redirect_to session_menu_path(script_name: nil), notice: "Account deleted"
  end

  private
    def ensure_owner
      head :forbidden unless Current.user.owner?
    end
end
```

The controller:
- Enforces owner-only access via `ensure_owner`
- Calls `cancel` on the current account
- Redirects to account menu (outside the cancelled account's scope)

### Step 3: Soft Delete (Cancellation)

**File:** `/app/models/account/cancellable.rb`

```ruby
def cancel(initiated_by: Current.user)
  with_lock do
    if cancellable? && active?
      run_callbacks :cancel do
        create_cancellation!(initiated_by: initiated_by)
      end

      AccountMailer.cancellation(cancellation).deliver_later
    end
  end
end
```

The `cancel` method:
1. Acquires a database lock to prevent race conditions
2. Checks `cancellable?` (multi-tenant mode) and `active?` (not already cancelled)
3. Runs any registered `:cancel` callbacks (e.g., subscription pausing)
4. Creates the `Account::Cancellation` record
5. Sends confirmation email to the owner

### Step 4: Confirmation Email

**Files:** `/app/mailers/account_mailer.rb`, `/app/views/mailers/account_mailer/cancellation.html.erb`

The email informs the user:
- No one can access the account anymore
- They will not be charged (if subscribed)
- Data will be permanently deleted in approximately 30 days
- They can email support@fizzy.do to restore the account

### Step 5: Grace Period (30 Days)

**File:** `/app/models/account/incineratable.rb`

```ruby
INCINERATION_GRACE_PERIOD = 30.days

scope :due_for_incineration, -> {
  joins(:cancellation)
    .where(account_cancellations: { created_at: ...INCINERATION_GRACE_PERIOD.ago })
}
```

The `due_for_incineration` scope finds accounts where the cancellation was created more than 30 days ago using the endless range (`...INCINERATION_GRACE_PERIOD.ago`).

### Step 6: Permanent Deletion (Incineration)

**File:** `/app/jobs/account/incinerate_due_job.rb`

```ruby
class Account::IncinerateDueJob < ApplicationJob
  include ActiveJob::Continuable

  queue_as :incineration

  def perform
    step :incineration do |step|
      Account.due_for_incineration.find_each do |account|
        account.incinerate
        step.checkpoint!
      end
    end
  end
end
```

This job:
- Runs every 8 hours (configured in `/config/recurring.yml`)
- Uses `ActiveJob::Continuable` for crash-resilient processing
- Iterates through all accounts due for incineration
- Calls `incinerate` on each one

**Incineration itself:**

```ruby
def incinerate
  run_callbacks :incinerate do
    account.destroy
  end
end
```

The `destroy` cascades to all associated records via `dependent: :destroy`:
- users, boards, cards, webhooks, tags, columns, exports, join_code

---

## Core Components

### Account::Cancellation Model

**File:** `/app/models/account/cancellation.rb`

```ruby
class Account::Cancellation < ApplicationRecord
  belongs_to :account
  belongs_to :initiated_by, class_name: "User"
end
```

A simple record tracking:
- Which account was cancelled
- Who initiated the cancellation
- When it happened (`created_at`)

**Database Schema:**

```ruby
# /db/migrate/20251224092315_create_account_cancellations.rb
create_table :account_cancellations, id: :uuid do |t|
  t.uuid :account_id, null: false, index: { unique: true }
  t.uuid :initiated_by_id, null: false
  t.timestamps
end
```

The unique index on `account_id` ensures an account can only have one cancellation record.

### Account::Cancellable Concern

**File:** `/app/models/account/cancellable.rb`

Provides:
- `cancel(initiated_by:)` - Creates cancellation and sends email
- `reactivate` - Destroys cancellation record
- `active?` / `cancelled?` - State predicates
- `cancellable?` - Whether deletion is allowed
- `Account.active` scope - Excludes cancelled accounts
- `:cancel` and `:reactivate` callbacks - Extension points

### Account::Incineratable Concern

**File:** `/app/models/account/incineratable.rb`

Provides:
- `INCINERATION_GRACE_PERIOD` - 30 days constant
- `Account.due_for_incineration` scope - Finds accounts ready for deletion
- `incinerate` - Permanently destroys the account
- `:incinerate` callback - Extension point for pre-destruction cleanup

### Scheduled Job

**File:** `/config/recurring.yml`

```yaml
incineration:
  class: "Account::IncinerateDueJob"
  schedule: every 8 hours at minute 16
```

The job runs three times daily, checking for accounts whose grace period has expired.

---

## Access Control During Cancellation

Once an account is cancelled, all access is blocked at multiple levels:

### Authenticated Access

**File:** `/app/controllers/concerns/authorization.rb`

```ruby
def ensure_can_access_account
  unless Current.account.active? && Current.user&.active?
    respond_to do |format|
      format.html { redirect_to session_menu_path(script_name: nil) }
      format.json { head :forbidden }
    end
  end
end
```

The `active?` check on `Current.account` blocks access to any cancelled account. Users are redirected to the account selection menu.

### Public Board Access

**File:** `/app/controllers/public/base_controller.rb`

```ruby
def ensure_board_accessible
  raise ActionController::RoutingError, "Not Found" if @board&.account&.cancelled?
end
```

Published boards return 404 if their account is cancelled.

### Webhooks

**File:** `/app/models/webhook/triggerable.rb`

```ruby
deliveries.create!(event: event) unless account.cancelled?
```

No webhook deliveries are created for cancelled accounts.

### Notifications

**File:** `/app/models/notification_pusher.rb`, `/app/models/notification/bundle.rb`

Notification delivery checks `account.active?` before sending, ensuring cancelled accounts receive no communications.

---

## SaaS Billing Integration

**File:** `/saas/app/models/account/billing.rb`

The SaaS deployment extends the deletion system with billing callbacks:

```ruby
included do
  set_callback :cancel, :after, -> { subscription&.pause }
  set_callback :reactivate, :before, -> { subscription&.resume }
  set_callback :incinerate, :before, -> { subscription&.cancel }
end
```

| Event | Subscription Action |
|-------|---------------------|
| Cancel | Pause (stops billing but retains subscription) |
| Reactivate | Resume (resumes billing) |
| Incinerate | Cancel (permanently ends subscription) |

This ensures:
- Users are not charged during the grace period
- Reactivation seamlessly resumes billing
- Final deletion cleans up the Stripe subscription

---

## Reactivation

Support staff can restore a cancelled account before incineration by calling:

```ruby
account.reactivate
```

**File:** `/app/models/account/cancellable.rb`

```ruby
def reactivate
  with_lock do
    if cancelled?
      run_callbacks :reactivate do
        cancellation.destroy
      end
    end
  end
end
```

This:
1. Acquires a lock to prevent race conditions
2. Runs any `:reactivate` callbacks (e.g., resuming subscription)
3. Destroys the cancellation record
4. Account is now `active?` again and users can log in

**Note:** There is no UI for reactivation. Users must contact support@fizzy.do, and support manually calls `account.reactivate` via Rails console.

---

## File Reference Index

### Models

| File | Purpose |
|------|---------|
| `/app/models/account.rb` | Main account model, includes Cancellable and Incineratable |
| `/app/models/account/cancellable.rb` | Soft delete logic, state predicates |
| `/app/models/account/cancellation.rb` | Cancellation record model |
| `/app/models/account/incineratable.rb` | Hard delete logic, grace period |
| `/app/models/account/multi_tenantable.rb` | `accepting_signups?` check |

### Controllers

| File | Purpose |
|------|---------|
| `/app/controllers/account/cancellations_controller.rb` | Handles deletion request |
| `/app/controllers/concerns/authorization.rb` | Blocks access to cancelled accounts |
| `/app/controllers/public/base_controller.rb` | Blocks public board access |

### Views

| File | Purpose |
|------|---------|
| `/app/views/account/settings/_cancellation.html.erb` | Delete button and confirmation dialog |
| `/app/views/mailers/account_mailer/cancellation.html.erb` | Confirmation email (HTML) |
| `/app/views/mailers/account_mailer/cancellation.text.erb` | Confirmation email (text) |

### Jobs

| File | Purpose |
|------|---------|
| `/app/jobs/account/incinerate_due_job.rb` | Scheduled incineration job |

### Configuration

| File | Purpose |
|------|---------|
| `/config/recurring.yml` | Job schedule (every 8 hours) |
| `/config/routes.rb` | `resource :cancellation` route |

### Tests

| File | Purpose |
|------|---------|
| `/test/models/account/cancellable_test.rb` | Cancellation logic tests |
| `/test/models/account/incineratable_test.rb` | Incineration logic tests |
| `/test/jobs/account/incinerate_due_job_test.rb` | Job execution tests |
| `/test/controllers/account/cancellations_controller_test.rb` | Controller tests |

### Database

| File | Purpose |
|------|---------|
| `/db/migrate/20251224092315_create_account_cancellations.rb` | Creates cancellation table |

### SaaS Extensions

| File | Purpose |
|------|---------|
| `/saas/app/models/account/billing.rb` | Subscription callbacks |
| `/saas/test/models/account/billing_test.rb` | Billing integration tests |
