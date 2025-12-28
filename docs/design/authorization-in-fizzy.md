# Authorization System

This document explains how Fizzy handles authorization - determining what authenticated users are allowed to do. For authentication (verifying user identity), see the magic link system.

## Overview

Fizzy uses a **model-centric authorization pattern** rather than a separate policy layer (like Pundit or CanCanCan). Authorization logic lives directly in the domain models and is enforced through:

1. **Association scoping** - Finding records through user associations naturally limits access
2. **Role-based permissions** - `can_*` methods on User check role-based privileges
3. **Controller guards** - `before_action` callbacks enforce permission checks

This approach aligns with Fizzy's "vanilla Rails" philosophy: thin controllers invoking a rich domain model without intermediate service layers or policy objects.

## Authorization Layers

### Layer 1: Account-Level Access

The foundational authorization layer ensures users can only access their own tenant.

**How it works:**

1. URL middleware (`AccountSlug::Extractor`) extracts the account ID from the URL path
2. `Current.account` is set from the URL
3. `Authentication` concern's `require_account` ensures an account is present
4. `Authorization` concern's `ensure_can_access_account` verifies the user belongs to that account

```ruby
# app/controllers/concerns/authorization.rb
module Authorization
  included do
    before_action :ensure_can_access_account, if: -> { Current.account.present? && authenticated? }
  end

  private
    def ensure_can_access_account
      if Current.user.blank? || !Current.user.active?
        respond_to do |format|
          format.html { redirect_to session_menu_path(script_name: nil) }
          format.json { head :forbidden }
        end
      end
    end
end
```

**Key insight:** `Current.user` is set by finding the user through the identity AND account:

```ruby
# app/models/current.rb
def identity=(identity)
  super(identity)
  if identity.present?
    self.user = identity.users.find_by(account: account)
  end
end
```

If the identity has no user in the current account, `Current.user` will be nil, and access is denied.

### Layer 2: Board-Level Access

Not all users can access all boards. Fizzy uses explicit `Access` records to control board visibility.

**The Access Model:**

```ruby
# app/models/access.rb
class Access < ApplicationRecord
  belongs_to :account, default: -> { user.account }
  belongs_to :board, touch: true
  belongs_to :user, touch: true

  enum :involvement, %i[ access_only watching ].index_by(&:itself), default: :access_only
end
```

**Board Access Modes:**

1. **All Access Boards** - Every active user in the account automatically gets an Access record
2. **Selective Access Boards** - Only specific users have Access records

**Automatic Access Grant:**

```ruby
# app/models/board/accessible.rb - When board becomes all_access
def grant_access_to_everyone
  accesses.grant_to(account.users.active) if all_access_previously_changed?(to: true)
end

# app/models/user/accessor.rb - When user is created
def grant_access_to_boards
  Access.insert_all account.boards.all_access.pluck(:id).collect { |board_id|
    { id: ActiveRecord::Type::Uuid.generate, board_id: board_id, user_id: id, account_id: account.id }
  }
end
```

**Authorization via Association Scoping:**

Controllers find boards through the user's `boards` association, which goes through Access:

```ruby
# app/models/user/accessor.rb
has_many :accesses, dependent: :destroy
has_many :boards, through: :accesses
has_many :accessible_columns, through: :boards, source: :columns
has_many :accessible_cards, through: :boards, source: :cards
has_many :accessible_comments, through: :accessible_cards, source: :comments
```

Controllers use these associations:

```ruby
# app/controllers/boards_controller.rb
def set_board
  @board = Current.user.boards.find params[:id]  # Only finds boards user has access to
end

# app/controllers/cards_controller.rb
def set_card
  @card = Current.user.accessible_cards.find_by!(number: params[:id])
end
```

**Why this works:** If a user doesn't have an Access record for a board, `find` raises `RecordNotFound`, returning a 404 - the user can't even confirm the board exists.

### Layer 3: Role-Based Permissions

Within accessible resources, different users have different capabilities based on their role.

**User Roles:**

```ruby
# app/models/user/role.rb
enum :role, %i[ owner admin member system ].index_by(&:itself), scopes: false

# Role hierarchy: owner > admin > member
def admin?
  super || owner?  # Owners are also admins
end
```

| Role | Capabilities |
|------|-------------|
| `owner` | Full control. Cannot be demoted by admins. Only one per account. |
| `admin` | Can manage users (except owner), boards, webhooks, account settings |
| `member` | Can access boards, create/edit cards, comments |
| `system` | Internal use (e.g., automated card creation). No board access. |

**Permission Methods:**

```ruby
# app/models/user/role.rb
def can_change?(other)
  (admin? && !other.owner?) || other == self
end

def can_administer?(other)
  admin? && !other.owner? && other != self
end

def can_administer_board?(board)
  admin? || board.creator == self
end

def can_administer_card?(card)
  admin? || card.creator == self
end
```

**Key pattern:** Creator-based permissions allow non-admins to manage resources they created.

### Layer 4: Controller Enforcement

Controllers use `before_action` callbacks to check permissions:

```ruby
# app/controllers/boards_controller.rb
class BoardsController < ApplicationController
  before_action :set_board, except: %i[ index new create ]
  before_action :ensure_permission_to_admin_board, only: %i[ update destroy ]

  private
    def ensure_permission_to_admin_board
      head :forbidden unless Current.user.can_administer_board?(@board)
    end
end

# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  include BoardScoped
  before_action :ensure_admin  # From Authorization concern
end
```

**Common Permission Guards:**

| Method | Defined In | Purpose |
|--------|-----------|---------|
| `ensure_admin` | `Authorization` concern | Requires admin or owner role |
| `ensure_staff` | `Authorization` concern | Requires staff flag on Identity (for internal admin) |
| `ensure_permission_to_admin_board` | `BoardsController` | Creator or admin can modify |
| `ensure_permission_to_administer_card` | `CardsController` | Creator or admin can delete |
| `ensure_permission_to_change_user` | `UsersController` | Admin (not owner), or self |
| `ensure_permission_to_administer_user` | `Users::RolesController` | Admin only, not for owner |

### Layer 5: View-Level Authorization

Views use the same `can_*` methods to show/hide UI elements:

```erb
<!-- app/views/boards/edit.html.erb -->
<% unless Current.user.can_administer_board?(@board) %>
  <p class="notice">You can view these settings but cannot change them.</p>
<% end %>

<!-- app/views/account/settings/show.html.erb -->
<% if Current.user.admin? %>
  <button type="submit">Save</button>
<% end %>

<!-- app/views/cards/_messages.html.erb -->
<% if Current.user.can_administer_card?(card) %>
  <%= link_to "Delete", card_path(card), method: :delete %>
<% end %>
```

**Important:** View-level checks are for UX only. Controller guards are the authoritative enforcement.

## Special Cases

### Public/Published Boards

Published boards bypass authentication entirely using a secret key:

```ruby
# app/controllers/public/base_controller.rb
class Public::BaseController < ApplicationController
  allow_unauthenticated_access  # Skips authentication AND authorization

  private
    def set_board
      @board = Board.find_by_published_key(params[:board_id] || params[:id])
    end
end
```

The `Board::Publication` model generates a random key that serves as a capability URL - anyone with the key can view the board.

### Staff Access

For internal administration (outside tenant context):

```ruby
# app/controllers/admin_controller.rb
class AdminController < ApplicationController
  disallow_account_scope  # No tenant context
  before_action :ensure_staff
end

# Authorization concern
def ensure_staff
  head :forbidden unless Current.identity.staff?
end
```

The `staff` boolean on `Identity` is set manually in the database - there's no UI to grant it.

### API Token Authorization

API requests use bearer tokens with explicit method permissions:

```ruby
# app/controllers/concerns/authentication.rb
def authenticate_by_bearer_token
  if request.authorization.to_s.include?("Bearer")
    authenticate_or_request_with_http_token do |token|
      if identity = Identity.find_by_permissable_access_token(token, method: request.method)
        Current.identity = identity
      end
    end
  end
end
```

Tokens can be scoped to specific HTTP methods (GET only, or full access).

## Access Cleanup

When a user loses board access, Fizzy cleans up orphaned data:

```ruby
# app/models/access.rb
after_destroy_commit :clean_inaccessible_data_later

def clean_inaccessible_data_later
  Board::CleanInaccessibleDataJob.perform_later(user, board)
end

# app/models/board/accessible.rb
def clean_inaccessible_data_for(user)
  return if accessible_to?(user)

  mentions_for_user(user).destroy_all
  notifications_for_user(user).destroy_all
  watches_for(user).destroy_all
end
```

## Comparison with Pundit

Pundit is the most popular Rails authorization gem. Here's how Fizzy's approach compares:

### Pundit Approach

```ruby
# app/policies/board_policy.rb
class BoardPolicy < ApplicationPolicy
  def update?
    user.admin? || record.creator == user
  end

  def destroy?
    user.admin? || record.creator == user
  end

  class Scope < Scope
    def resolve
      user.boards
    end
  end
end

# Controller
class BoardsController < ApplicationController
  def update
    @board = Board.find(params[:id])
    authorize @board
    @board.update!(board_params)
  end
end
```

### Fizzy Approach

```ruby
# app/models/user/role.rb
def can_administer_board?(board)
  admin? || board.creator == self
end

# Controller
class BoardsController < ApplicationController
  before_action :set_board
  before_action :ensure_permission_to_admin_board, only: %i[ update destroy ]

  private
    def set_board
      @board = Current.user.boards.find(params[:id])  # Scoping handles basic access
    end

    def ensure_permission_to_admin_board
      head :forbidden unless Current.user.can_administer_board?(@board)
    end
end
```

### Trade-offs

| Aspect | Pundit | Fizzy's Approach |
|--------|--------|-----------------|
| **Discoverability** | All policies in `app/policies/` | Permission logic spread across models |
| **Testing** | Dedicated policy specs | Permission methods tested on User model |
| **Consistency** | `authorize` enforced by Pundit::NotAuthorizedError | Manual `before_action` - could forget |
| **Scoping** | `policy_scope` helper | Association scoping (more natural) |
| **Dependencies** | External gem | Zero dependencies |
| **Flexibility** | Structured pattern | Ad-hoc, fits specific needs |
| **Domain fit** | Generic pattern | Logic lives where it conceptually belongs |
| **Complexity** | Learning curve for policy pattern | Simpler mental model |

### When Each Approach Shines

**Fizzy's approach works well when:**
- Authorization rules are relatively simple and role-based
- Permission checks naturally relate to domain concepts (creator, admin)
- Team prefers keeping logic in models over separate policy layer
- Scoping through associations handles most access control

**Pundit shines when:**
- Complex, context-dependent authorization rules
- Many resources with varying permission patterns
- Team wants consistent authorization API across all controllers
- Need for comprehensive policy testing in isolation

## Implementation Checklist

When adding a new resource to Fizzy:

1. **Decide access model:**
   - Account-wide? Use `Current.account.resources`
   - Board-scoped? Scope through `Current.user.boards` or `accessible_*`
   - User-specific? Direct association from `Current.user`

2. **Add permission methods if needed:**
   ```ruby
   # In User::Role or a new concern
   def can_administer_widget?(widget)
     admin? || widget.creator == self
   end
   ```

3. **Add controller guards:**
   ```ruby
   before_action :set_widget
   before_action :ensure_can_administer_widget, only: %i[ update destroy ]
   ```

4. **Update views:**
   - Use `can_*` methods to conditionally show UI
   - Always trust controller as source of truth

5. **Write tests:**
   - Test permission methods on User
   - Test controller returns 403/404 for unauthorized access

## Files Reference

| File | Purpose |
|------|---------|
| `app/models/access.rb` | Board-user access record |
| `app/models/user/role.rb` | Role enum and permission methods |
| `app/models/user/accessor.rb` | User associations to accessible resources |
| `app/models/board/accessible.rb` | Board access management |
| `app/controllers/concerns/authorization.rb` | Account-level guards and admin checks |
| `app/controllers/concerns/authentication.rb` | Unauthenticated access control |
| `app/controllers/concerns/board_scoped.rb` | Board finding and permission check |
| `app/controllers/concerns/card_scoped.rb` | Card finding through accessible_cards |

---

## Hypothetical: Reimplementing with Pundit

This section shows how Fizzy's authorization would look if reimplemented using [Pundit](https://github.com/varvet/pundit), the popular Ruby authorization gem. This is a hypothetical exercise to illustrate trade-offs and help teams familiar with Pundit understand Fizzy's patterns.

### Setup and Configuration

First, add Pundit and configure the application:

```ruby
# Gemfile
gem "pundit"

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include Authentication
  # Remove: include Authorization (replaced by Pundit)

  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private
    def user_not_authorized
      respond_to do |format|
        format.html { redirect_to root_path, alert: "You are not authorized to perform this action." }
        format.json { head :forbidden }
      end
    end

    # Pundit uses current_user by default; we use Current.user
    def pundit_user
      Current.user
    end
end
```

### The Base Application Policy

```ruby
# app/policies/application_policy.rb
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  # Default: deny everything
  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def new?
    create?
  end

  def update?
    false
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  # Convenience methods matching Fizzy's role system
  def admin?
    user.admin?
  end

  def owner?
    user.owner?
  end

  def creator?
    record.respond_to?(:creator) && record.creator == user
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise NotImplementedError, "You must define #resolve in #{self.class}"
    end

    private
      attr_reader :user, :scope
  end
end
```

### Board Policy

The `BoardPolicy` translates Fizzy's `can_administer_board?` and Access-based scoping:

```ruby
# app/policies/board_policy.rb
class BoardPolicy < ApplicationPolicy
  # Anyone with board access can view
  def show?
    has_access?
  end

  # Anyone can create boards
  def create?
    true
  end

  # Creator or admin can update
  def update?
    has_access? && (admin? || creator?)
  end

  # Creator or admin can destroy
  def destroy?
    has_access? && (admin? || creator?)
  end

  # Only admins can manage webhooks
  def manage_webhooks?
    has_access? && admin?
  end

  # Only board administrators can publish
  def publish?
    update?
  end

  # Only board administrators can manage access
  def manage_access?
    update?
  end

  private
    def has_access?
      # Check if user has an Access record for this board
      user.boards.exists?(record.id)
    end

  class Scope < Scope
    def resolve
      # Return only boards the user has access to
      # This replaces Current.user.boards
      user.boards
    end
  end
end
```

### Card Policy

The `CardPolicy` handles card-level permissions, inheriting board access:

```ruby
# app/policies/card_policy.rb
class CardPolicy < ApplicationPolicy
  # Anyone with board access can view cards
  def show?
    has_board_access?
  end

  # Anyone with board access can create cards
  def create?
    has_board_access?
  end

  # Anyone with board access can update cards
  def update?
    has_board_access?
  end

  # Only creator or admin can destroy
  # This translates can_administer_card?
  def destroy?
    has_board_access? && (admin? || creator?)
  end

  # Card-specific actions
  def close?
    has_board_access?
  end

  def reopen?
    has_board_access?
  end

  def move?
    has_board_access?
  end

  def assign?
    has_board_access?
  end

  private
    def has_board_access?
      user.boards.exists?(record.board_id)
    end

  class Scope < Scope
    def resolve
      # Return cards from boards the user can access
      # This replaces Current.user.accessible_cards
      scope.joins(:board).merge(user.boards)
    end
  end
end
```

### Comment Policy

Comments have stricter edit/delete rules - only the creator can modify:

```ruby
# app/policies/comment_policy.rb
class CommentPolicy < ApplicationPolicy
  def show?
    has_card_access?
  end

  def create?
    has_card_access?
  end

  # Only the comment creator can edit
  # This is stricter than card permissions
  def update?
    has_card_access? && creator?
  end

  # Only the comment creator can delete
  def destroy?
    has_card_access? && creator?
  end

  private
    def has_card_access?
      user.accessible_cards.exists?(record.card_id)
    end

  class Scope < Scope
    def resolve
      # Comments on cards the user can access
      scope.joins(card: :board).merge(user.boards)
    end
  end
end
```

### User Policy

User management has complex rules around role hierarchy:

```ruby
# app/policies/user_policy.rb
class UserPolicy < ApplicationPolicy
  def index?
    true  # All users can see the user list
  end

  def show?
    true  # All users can view profiles
  end

  # Users can update themselves, admins can update non-owners
  # Translates can_change?
  def update?
    record == user || (admin? && !record.owner?)
  end

  # Same as update for deactivation
  def destroy?
    update?
  end

  # Only admins can change roles, and not for owners or themselves
  # Translates can_administer?
  def change_role?
    admin? && !record.owner? && record != user
  end

  class Scope < Scope
    def resolve
      # Users can see all active users in their account
      scope.where(account: user.account, active: true)
    end
  end
end
```

### Account Policy (Headless Policy)

For account-level settings that don't have a specific record, use a headless policy:

```ruby
# app/policies/account_policy.rb
class AccountPolicy < ApplicationPolicy
  # Anyone can view account settings
  def show?
    true
  end

  # Only admins can update account settings
  def update?
    admin?
  end

  # Only admins can manage entropy settings
  def manage_entropy?
    admin?
  end

  # Only admins can manage join codes
  def manage_join_code?
    admin?
  end

  # Any user can create exports (of their own data)
  def create_export?
    true
  end
end
```

### Webhook Policy

Webhooks require admin privileges:

```ruby
# app/policies/webhook_policy.rb
class WebhookPolicy < ApplicationPolicy
  def index?
    has_board_access? && admin?
  end

  def show?
    has_board_access? && admin?
  end

  def create?
    has_board_access? && admin?
  end

  def update?
    has_board_access? && admin?
  end

  def destroy?
    has_board_access? && admin?
  end

  private
    def has_board_access?
      user.boards.exists?(record.board_id)
    end

  class Scope < Scope
    def resolve
      if user.admin?
        scope.joins(:board).merge(user.boards)
      else
        scope.none
      end
    end
  end
end
```

### Controller Changes

Here's how controllers would change to use Pundit:

#### BoardsController

```ruby
# app/controllers/boards_controller.rb
class BoardsController < ApplicationController
  before_action :set_board, except: %i[ index new create ]

  def index
    @boards = policy_scope(Board)
    set_page_and_extract_portion_from @boards
  end

  def show
    authorize @board
    # ... existing show logic
  end

  def new
    @board = Board.new
    authorize @board
  end

  def create
    @board = Board.new(board_params.with_defaults(all_access: true))
    authorize @board
    @board.save!
    redirect_to board_path(@board)
  end

  def edit
    authorize @board
    # ... existing edit logic
  end

  def update
    authorize @board
    @board.update!(board_params)
    @board.accesses.revise(granted: grantees, revoked: revokees) if grantees_changed?
    redirect_to edit_board_path(@board)
  end

  def destroy
    authorize @board
    @board.destroy
    redirect_to root_path
  end

  private
    def set_board
      # Still scope through user for 404 vs 403 behavior
      @board = Current.user.boards.find(params[:id])
    end

    # ... rest of private methods unchanged
end
```

#### CardsController

```ruby
# app/controllers/cards_controller.rb
class CardsController < ApplicationController
  before_action :set_board, only: %i[ create ]
  before_action :set_card, only: %i[ show edit update destroy ]

  def index
    @cards = policy_scope(Card)
    set_page_and_extract_portion_from @filter.cards.merge(@cards)
  end

  def create
    authorize @board, :show?  # Can create cards if has board access
    @card = @board.cards.create!(card_params.merge(creator: Current.user))
    head :created, location: card_path(@card)
  end

  def show
    authorize @card
  end

  def update
    authorize @card
    @card.update!(card_params)
  end

  def destroy
    authorize @card
    @card.destroy!
    redirect_to @card.board
  end

  private
    def set_board
      @board = policy_scope(Board).find(params[:board_id])
    end

    def set_card
      @card = policy_scope(Card).find_by!(number: params[:id])
    end
end
```

#### Cards::CommentsController

```ruby
# app/controllers/cards/comments_controller.rb
class Cards::CommentsController < ApplicationController
  include CardScoped

  before_action :set_comment, only: %i[ show edit update destroy ]

  def index
    @comments = policy_scope(@card.comments).chronologically
    set_page_and_extract_portion_from @comments
  end

  def create
    @comment = @card.comments.build(comment_params)
    authorize @comment
    @comment.save!
  end

  def show
    authorize @comment
  end

  def edit
    authorize @comment
  end

  def update
    authorize @comment
    @comment.update!(comment_params)
  end

  def destroy
    authorize @comment
    @comment.destroy
  end

  private
    def set_comment
      @comment = @card.comments.find(params[:id])
    end
end
```

#### WebhooksController

```ruby
# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  include BoardScoped

  before_action :set_webhook, except: %i[ index new create ]

  def index
    @webhooks = policy_scope(@board.webhooks).ordered
    set_page_and_extract_portion_from @webhooks
  end

  def new
    @webhook = @board.webhooks.new
    authorize @webhook
  end

  def create
    @webhook = @board.webhooks.build(webhook_params)
    authorize @webhook
    @webhook.save!
    redirect_to @webhook
  end

  def show
    authorize @webhook
  end

  def update
    authorize @webhook
    @webhook.update!(webhook_params.except(:url))
    redirect_to @webhook
  end

  def destroy
    authorize @webhook
    @webhook.destroy!
    redirect_to board_webhooks_path
  end

  private
    def set_webhook
      @webhook = @board.webhooks.find(params[:id])
    end
end
```

#### Account::SettingsController with Headless Policy

```ruby
# app/controllers/account/settings_controller.rb
class Account::SettingsController < ApplicationController
  before_action :set_account

  def show
    authorize @account
    @users = @account.users.active.alphabetically.includes(:identity)
  end

  def update
    authorize @account
    @account.update!(account_params)
    redirect_to account_settings_path
  end

  private
    def set_account
      @account = Current.account
    end
end
```

### View Changes

Views would use Pundit's `policy` helper instead of `can_*` methods:

```erb
<!-- Before: Fizzy's approach -->
<% if Current.user.can_administer_board?(@board) %>
  <%= link_to "Delete", board_path(@board), method: :delete %>
<% end %>

<!-- After: Pundit approach -->
<% if policy(@board).destroy? %>
  <%= link_to "Delete", board_path(@board), method: :delete %>
<% end %>

<!-- Before -->
<% if Current.user.admin? %>
  <%= link_to "Webhooks", board_webhooks_path(@board) %>
<% end %>

<!-- After -->
<% if policy(@board).manage_webhooks? %>
  <%= link_to "Webhooks", board_webhooks_path(@board) %>
<% end %>

<!-- Before -->
<% unless Current.user.can_administer_board?(@board) %>
  <p class="notice">You can view but not edit.</p>
<% end %>

<!-- After -->
<% unless policy(@board).update? %>
  <p class="notice">You can view but not edit.</p>
<% end %>
```

### Testing Policies

Pundit policies can be tested in isolation using Minitest:

```ruby
# test/policies/board_policy_test.rb
require "test_helper"

class BoardPolicyTest < ActiveSupport::TestCase
  def setup
    @board = boards(:writebook)
  end

  test "board creator can show, update, and destroy" do
    policy = BoardPolicy.new(@board.creator, @board)

    assert policy.show?
    assert policy.update?
    assert policy.destroy?
  end

  test "admin with access can show, update, and destroy" do
    admin = users(:kevin)  # admin user
    @board.accesses.create!(user: admin)
    policy = BoardPolicy.new(admin, @board)

    assert policy.show?
    assert policy.update?
    assert policy.destroy?
  end

  test "member with access can show but not update or destroy" do
    member = users(:jz)  # member user
    @board.accesses.create!(user: member)
    policy = BoardPolicy.new(member, @board)

    assert policy.show?
    assert_not policy.update?
    assert_not policy.destroy?
  end

  test "user without access cannot show, update, or destroy" do
    user_without_access = users(:jz)
    policy = BoardPolicy.new(user_without_access, @board)

    assert_not policy.show?
    assert_not policy.update?
    assert_not policy.destroy?
  end

  test "scope returns only boards user has access to" do
    user = users(:kevin)
    scope = BoardPolicy::Scope.new(user, Board).resolve

    assert_equal user.boards.to_a.sort, scope.to_a.sort
  end
end
```

```ruby
# test/policies/comment_policy_test.rb
require "test_helper"

class CommentPolicyTest < ActiveSupport::TestCase
  def setup
    @comment = comments(:logo_comment)
  end

  test "comment creator can update and destroy" do
    policy = CommentPolicy.new(@comment.creator, @comment)

    assert policy.update?
    assert policy.destroy?
  end

  test "admin who is not the creator cannot update or destroy" do
    admin = users(:kevin)
    policy = CommentPolicy.new(admin, @comment)

    assert_not policy.update?
    assert_not policy.destroy?
  end

  test "card creator who is not the comment creator cannot update or destroy" do
    card_creator = @comment.card.creator
    policy = CommentPolicy.new(card_creator, @comment)

    assert_not policy.update?
    assert_not policy.destroy?
  end
end
```

### Namespaced Policies

For nested resources like `Account::JoinCode`, use namespaced policies:

```ruby
# app/policies/account/join_code_policy.rb
module Account
  class JoinCodePolicy < ApplicationPolicy
    def show?
      true  # All account members can view
    end

    def update?
      admin?
    end

    def destroy?
      admin?
    end
  end
end
```

### Special Cases with Pundit

#### Skipping Authorization for Public Routes

```ruby
# app/controllers/public/base_controller.rb
class Public::BaseController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  # ... rest unchanged
end
```

#### Staff-Only Admin Routes

```ruby
# app/policies/admin_policy.rb
class AdminPolicy < ApplicationPolicy
  def initialize(user, record)
    # For admin routes, check the identity's staff flag
    @identity = Current.identity
    super
  end

  def access?
    @identity&.staff?
  end
end

# app/controllers/admin_controller.rb
class AdminController < ApplicationController
  skip_after_action :verify_authorized
  before_action :authorize_staff

  private
    def authorize_staff
      authorize :admin, :access?
    end
end
```

### Summary: What Changes with Pundit

| Aspect | Fizzy Current | With Pundit |
|--------|---------------|-------------|
| **Permission logic** | `User::Role` concern | Individual policy files |
| **Controller checks** | `before_action` + manual methods | `authorize` + policy methods |
| **Scoping** | `Current.user.boards` association | `policy_scope(Board)` |
| **View checks** | `Current.user.can_*` | `policy(@record).action?` |
| **Forgotten auth** | Silent failure | `Pundit::AuthorizationNotPerformedError` |
| **Testing** | User model tests | Dedicated policy specs |
| **File organization** | Spread across models/concerns | Centralized in `app/policies/` |

### Migration Path

If migrating Fizzy to Pundit:

1. **Add gem and base configuration** (ApplicationPolicy, ApplicationController changes)
2. **Create policies one resource at a time**, keeping existing `can_*` methods
3. **Update controllers** to use `authorize` and `policy_scope`
4. **Update views** to use `policy(@record).action?`
5. **Remove old `can_*` methods** from `User::Role` once all consumers migrated
6. **Enable `verify_authorized`** to catch forgotten authorization

The key insight: Pundit and Fizzy's approach are not mutually exclusive. You could use Pundit while keeping `can_*` methods on models if those methods represent genuine domain concepts beyond just authorization.
