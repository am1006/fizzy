# Multi-Tenancy Implementation Guide

This guide explains how to implement URL path-based multi-tenancy in a Rails application, based on patterns used in Fizzy. By the end, you'll have a system where multiple organizations (tenants) share a single application instance with complete data isolation.

## Table of Contents

1. [Overview](#overview)
2. [Database Schema](#database-schema)
3. [Core Models](#core-models)
4. [URL-Based Tenancy Middleware](#url-based-tenancy-middleware)
5. [Current Attributes](#current-attributes)
6. [Authentication Flow](#authentication-flow)
7. [Authorization](#authorization)
8. [Background Jobs](#background-jobs)
9. [Route Helpers and URL Generation](#route-helpers-and-url-generation)
10. [Common Patterns](#common-patterns)
11. [Testing](#testing)

---

## Overview

### What We're Building

A multi-tenancy system where:

- Each organization (Account) has a unique numeric ID in the URL path
- URLs look like: `https://app.example.com/1234567/boards/abc`
- One person (Identity) can belong to multiple organizations
- Each organization membership is represented by a User record
- All data is isolated by `account_id` on every table

### Why This Approach?

| Approach | Pros | Cons |
|----------|------|------|
| **Subdomain-based** (`acme.app.com`) | Clean URLs | Complex local development, DNS/SSL per tenant |
| **Separate databases** | Complete isolation | Operational complexity, cross-tenant queries impossible |
| **Schema-per-tenant** | Good isolation | Migration complexity, connection pooling issues |
| **URL path-based** (our choice) | Simple local dev, works everywhere, easy migrations | Slightly longer URLs |

The URL path approach gives us:

1. **Zero infrastructure complexity** - No subdomain configuration
2. **Local development simplicity** - Just `localhost:3000/1234567/`
3. **Single database** - Standard migrations, backups, queries
4. **Automatic URL generation** - Rails route helpers just work

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Request Flow                             │
└─────────────────────────────────────────────────────────────────┘

  Request: GET /1234567/boards
              │
              ▼
  ┌───────────────────────┐
  │  AccountSlug::Extractor│  Rack Middleware
  │  (extracts tenant ID)  │
  └───────────────────────┘
              │
              │  Sets Current.account
              │  Moves /1234567 to SCRIPT_NAME
              │  PATH_INFO becomes /boards
              ▼
  ┌───────────────────────┐
  │   Rails Router         │
  └───────────────────────┘
              │
              ▼
  ┌───────────────────────┐
  │  Authentication        │  Finds Session → Identity → User
  │  Concern               │  Sets Current.user for this Account
  └───────────────────────┘
              │
              ▼
  ┌───────────────────────┐
  │   Controller           │  All queries scoped to Current.account
  └───────────────────────┘


┌─────────────────────────────────────────────────────────────────┐
│                    Identity / User Model                         │
└─────────────────────────────────────────────────────────────────┘

                    ┌──────────────┐
                    │   Identity   │  Global (no account_id)
                    │              │  email: user@example.com
                    └──────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │   User     │  │   User     │  │   User     │
    │ Account: A │  │ Account: B │  │ Account: C │
    │ role: owner│  │ role: admin│  │ role:member│
    └────────────┘  └────────────┘  └────────────┘
```

---

## Database Schema

### Migration 1: Create Accounts Table

The Account is your tenant. Each account has an `external_account_id` used in URLs (separate from the internal primary key for security).

```ruby
# db/migrate/001_create_accounts.rb
class CreateAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :accounts, id: :uuid do |t|
      t.string :name, null: false
      t.bigint :external_account_id, null: false

      t.timestamps

      t.index :external_account_id, unique: true
    end
  end
end
```

**Why `external_account_id`?**

- Security: Don't expose internal UUIDs in URLs
- Aesthetics: Short, memorable numeric IDs
- Stability: Can change primary key strategy without affecting URLs

### Migration 2: Create External ID Sequence

Generate sequential external IDs atomically:

```ruby
# db/migrate/002_create_account_external_id_sequences.rb
class CreateAccountExternalIdSequences < ActiveRecord::Migration[7.1]
  def change
    create_table :account_external_id_sequences, id: :uuid do |t|
      t.bigint :value, null: false, default: 0

      t.index :value, unique: true
    end
  end
end
```

### Migration 3: Create Identities Table

Identities are global users identified by email:

```ruby
# db/migrate/003_create_identities.rb
class CreateIdentities < ActiveRecord::Migration[7.1]
  def change
    create_table :identities, id: :uuid do |t|
      t.string :email_address, null: false

      t.timestamps

      t.index :email_address, unique: true
    end
  end
end
```

**Key insight**: Identities have NO `account_id`. They exist outside the tenant boundary.

### Migration 4: Create Sessions Table

Sessions belong to Identity (not User), enabling cross-account authentication:

```ruby
# db/migrate/004_create_sessions.rb
class CreateSessions < ActiveRecord::Migration[7.1]
  def change
    create_table :sessions, id: :uuid do |t|
      t.references :identity, null: false, foreign_key: true, type: :uuid
      t.string :ip_address
      t.string :user_agent, limit: 4096

      t.timestamps

      t.index :identity_id
    end
  end
end
```

### Migration 5: Create Users Table

Users bridge Identity to Account:

```ruby
# db/migrate/005_create_users.rb
class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :identity, foreign_key: true, type: :uuid  # nullable for system users
      t.string :name, null: false
      t.string :role, null: false, default: 'member'
      t.boolean :active, null: false, default: true

      t.timestamps

      t.index [:account_id, :identity_id], unique: true
      t.index [:account_id, :role]
    end
  end
end
```

### Migration 6: Create Magic Links Table

For passwordless authentication:

```ruby
# db/migrate/006_create_magic_links.rb
class CreateMagicLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :magic_links, id: :uuid do |t|
      t.references :identity, foreign_key: true, type: :uuid
      t.string :code, null: false
      t.integer :purpose, null: false, default: 0  # 0 = sign_in, 1 = sign_up
      t.datetime :expires_at, null: false

      t.timestamps

      t.index :code, unique: true
      t.index :expires_at
    end
  end
end
```

### Adding account_id to Other Tables

Every tenant-scoped table needs `account_id`:

```ruby
# db/migrate/007_create_boards.rb
class CreateBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :boards, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :creator, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :name, null: false

      t.timestamps

      t.index :account_id
    end
  end
end
```

---

## Core Models

### Account Model

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :boards, dependent: :destroy
  # Add all tenant-scoped associations here

  validates :name, presence: true

  before_create :assign_external_account_id

  class << self
    def create_with_owner(account:, owner:)
      create!(**account).tap do |account|
        # Create a system user for automated actions
        account.users.create!(role: :system, name: "System")
        # Create the owner
        account.users.create!(**owner.merge(role: :owner))
      end
    end
  end

  # Generate the URL path prefix for this account
  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  # Convenience method for scoping (account.account returns self)
  def account
    self
  end

  # Get the system user for automated actions
  def system_user
    users.find_by!(role: :system)
  end

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end
```

### External ID Sequence

Generates unique, sequential external IDs with database-level locking:

```ruby
# app/models/account/external_id_sequence.rb
class Account::ExternalIdSequence < ApplicationRecord
  self.table_name = 'account_external_id_sequences'

  class << self
    def next
      with_lock do |sequence|
        sequence.increment!(:value).value
      end
    end

    def value
      first&.value || self.next
    end

    private
      def with_lock
        transaction do
          sequence = lock.first_or_create!(value: initial_value)
          yield sequence
        end
      end

      def initial_value
        Account.maximum(:external_account_id) || 1_000_000  # Start at 7 digits
      end
  end
end
```

### Identity Model

The global user entity:

```ruby
# app/models/identity.rb
class Identity < ApplicationRecord
  has_many :sessions, dependent: :destroy
  has_many :magic_links, dependent: :destroy
  has_many :users, dependent: :nullify
  has_many :accounts, through: :users

  validates :email_address,
    presence: true,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }

  normalizes :email_address, with: ->(value) { value.strip.downcase }

  def send_magic_link(purpose: :sign_in)
    magic_links.create!(purpose: purpose).tap do |magic_link|
      MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
    end
  end

  # Join an account, creating a User if needed
  def join(account, **attributes)
    attributes[:name] ||= email_address

    transaction do
      account.users.find_or_create_by!(identity: self) do |user|
        user.assign_attributes(attributes)
      end.previously_new_record?
    end
  end
end
```

### User Model

The account membership:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  belongs_to :account
  belongs_to :identity, optional: true  # Optional for system users

  enum :role, {
    owner: 'owner',
    admin: 'admin',
    member: 'member',
    system: 'system'
  }, default: :member

  validates :name, presence: true

  scope :active, -> { where(active: true).where.not(role: :system) }

  def admin?
    role.in?(%w[owner admin])
  end

  def deactivate
    transaction do
      update!(active: false, identity: nil)
    end
  end
end
```

### Session Model

```ruby
# app/models/session.rb
class Session < ApplicationRecord
  belongs_to :identity
end
```

### Magic Link Model

```ruby
# app/models/magic_link.rb
class MagicLink < ApplicationRecord
  CODE_LENGTH = 6
  EXPIRATION_TIME = 15.minutes

  belongs_to :identity

  enum :purpose, { sign_in: 0, sign_up: 1 }, default: :sign_in

  scope :active, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ..Time.current) }

  before_validation :generate_code, on: :create
  before_validation :set_expiration, on: :create

  validates :code, uniqueness: true, presence: true

  class << self
    def consume(code)
      active.find_by(code: sanitize_code(code))&.consume
    end

    def cleanup
      expired.delete_all
    end

    private
      def sanitize_code(code)
        code.to_s.upcase.gsub(/[^A-Z0-9]/, '')
      end
  end

  def consume
    destroy
    self
  end

  private
    def generate_code
      self.code ||= loop do
        # Generate codes like "ABC123"
        candidate = SecureRandom.alphanumeric(CODE_LENGTH).upcase
        break candidate unless self.class.exists?(code: candidate)
      end
    end

    def set_expiration
      self.expires_at ||= EXPIRATION_TIME.from_now
    end
end
```

---

## URL-Based Tenancy Middleware

This is the heart of the system. The middleware:

1. Extracts the account ID from the URL path
2. Moves it to `SCRIPT_NAME` (Rails thinks it's "mounted" there)
3. Sets `Current.account` for the request duration

### AccountSlug Module

```ruby
# config/initializers/tenanting/account_slug.rb

module AccountSlug
  # Match 7+ digit account IDs
  PATTERN = /(\d{7,})/
  FORMAT = "%07d"
  PATH_INFO_MATCH = /\A(\/#{PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)

      # Case 1: Account ID already in SCRIPT_NAME (e.g., ActionCable reconnection)
      if request.script_name.present? && request.script_name =~ PATH_INFO_MATCH
        env["app.external_account_id"] = AccountSlug.decode($2)

      # Case 2: Account ID in PATH_INFO - extract and move to SCRIPT_NAME
      elsif request.path_info =~ PATH_INFO_MATCH
        # $1 = full match with slash (e.g., "/1234567")
        # $2 = just the digits (e.g., "1234567")
        # $' = everything after the match (e.g., "/boards")

        request.engine_script_name = request.script_name = $1
        request.path_info = $'.empty? ? "/" : $'

        env["app.external_account_id"] = AccountSlug.decode($2)
      end

      # Execute request within account context
      if env["app.external_account_id"]
        account = Account.find_by(external_account_id: env["app.external_account_id"])
        Current.with_account(account) do
          @app.call(env)
        end
      else
        Current.without_account do
          @app.call(env)
        end
      end
    end
  end

  def self.decode(slug)
    slug.to_i
  end

  def self.encode(id)
    FORMAT % id
  end
end

# Insert middleware early in the stack
Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

### How SCRIPT_NAME Works

When you move the account prefix to `SCRIPT_NAME`:

```
Before middleware:
  SCRIPT_NAME = ""
  PATH_INFO = "/1234567/boards/new"

After middleware:
  SCRIPT_NAME = "/1234567"
  PATH_INFO = "/boards/new"
```

Rails route helpers automatically prepend `SCRIPT_NAME`:

```ruby
boards_path  # => "/1234567/boards" (SCRIPT_NAME + "/boards")
```

This means ALL generated URLs automatically include the account prefix without any extra work.

### Testing the Middleware

```ruby
# test/middleware/account_slug_extractor_test.rb
require "test_helper"
require "rack/mock"

class AccountSlugExtractorTest < ActiveSupport::TestCase
  test "extracts account from path and sets Current.account" do
    account = accounts(:acme)
    slug = AccountSlug.encode(account.external_account_id)

    captured = call_with_env("/#{slug}/boards")

    assert_equal "/#{slug}", captured[:script_name]
    assert_equal "/boards", captured[:path_info]
    assert_equal account, captured[:current_account]
  end

  test "treats bare account prefix as root path" do
    account = accounts(:acme)
    slug = AccountSlug.encode(account.external_account_id)

    captured = call_with_env("/#{slug}")

    assert_equal "/", captured[:path_info]
  end

  test "clears Current.account when no prefix present" do
    captured = call_with_env("/login")

    assert_equal "", captured[:script_name]
    assert_nil captured[:current_account]
  end

  private
    def call_with_env(path)
      captured = {}

      app = ->(env) do
        captured[:script_name] = env["SCRIPT_NAME"]
        captured[:path_info] = env["PATH_INFO"]
        captured[:current_account] = Current.account
        [200, {}, ["ok"]]
      end

      middleware = AccountSlug::Extractor.new(app)
      env = Rack::MockRequest.env_for(path, method: "GET")
      env["action_dispatch.routes"] = Rails.application.routes

      middleware.call(env)
      captured
    end
end
```

---

## Current Attributes

Rails' `CurrentAttributes` provides thread-safe, request-scoped storage:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  attribute :request_id, :user_agent, :ip_address

  # When session is set, automatically set identity
  def session=(value)
    super(value)
    self.identity = session&.identity
  end

  # When identity is set (with an account context), find the User
  def identity=(value)
    super(value)
    if identity.present? && account.present?
      self.user = identity.users.find_by(account: account)
    end
  end

  # Execute a block within an account context
  def with_account(value, &block)
    with(account: value, &block)
  end

  # Execute a block outside any account context
  def without_account(&block)
    with(account: nil, &block)
  end
end
```

### How Current Works

```ruby
# In middleware - sets account
Current.with_account(account) do
  # All code in this block sees Current.account
end

# In authentication - sets session (cascades to identity and user)
Current.session = session
# Now Current.identity and Current.user are also set

# In controllers
Current.account  # => The current tenant
Current.user     # => The User in this tenant for the logged-in Identity
Current.identity # => The global Identity
```

---

## Authentication Flow

### Controller Concerns

```ruby
# app/controllers/concerns/authentication.rb
module Authentication
  extend ActiveSupport::Concern

  included do
    # Account check must happen first
    before_action :require_account
    before_action :require_authentication

    helper_method :authenticated?
  end

  class_methods do
    # Mark controllers that should NOT require authentication
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
      before_action :resume_session, **options
    end

    # Mark controllers that operate outside tenant context (login, signup)
    def disallow_account_scope(**options)
      skip_before_action :require_account, **options
      before_action :redirect_tenanted_request, **options
    end
  end

  private
    def authenticated?
      Current.identity.present?
    end

    def require_account
      unless Current.account.present?
        redirect_to session_menu_path(script_name: nil)
      end
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      if session = find_session_by_cookie
        Current.session = session
      end
    end

    def find_session_by_cookie
      Session.find_signed(cookies.signed[:session_token])
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path(script_name: nil)
    end

    def start_new_session_for(identity)
      identity.sessions.create!(
        user_agent: request.user_agent,
        ip_address: request.remote_ip
      ).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_token] = {
          value: session.signed_id,
          httponly: true,
          same_site: :lax
        }
      end
    end

    def terminate_session
      Current.session&.destroy
      cookies.delete(:session_token)
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_path
    end

    def redirect_tenanted_request
      redirect_to root_url if Current.account.present?
    end
end
```

### Sessions Controller

```ruby
# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  disallow_account_scope
  allow_unauthenticated_access

  layout "public"

  def new
  end

  def create
    if identity = Identity.find_by(email_address: email_address)
      magic_link = identity.send_magic_link
      redirect_to session_magic_link_path, notice: "Check your email for a sign-in link"
    else
      # Don't reveal whether email exists - send to same page
      redirect_to session_magic_link_path, notice: "Check your email for a sign-in link"
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path
  end

  private
    def email_address
      params.require(:email_address)
    end
end
```

### Magic Links Controller

```ruby
# app/controllers/sessions/magic_links_controller.rb
class Sessions::MagicLinksController < ApplicationController
  disallow_account_scope
  allow_unauthenticated_access

  layout "public"

  def show
    # Display code entry form
  end

  def create
    if magic_link = MagicLink.consume(params[:code])
      start_new_session_for(magic_link.identity)
      redirect_to after_sign_in_url(magic_link)
    else
      redirect_to session_magic_link_path, alert: "Invalid or expired code"
    end
  end

  private
    def after_sign_in_url(magic_link)
      if magic_link.sign_up?
        # New user - complete signup
        new_signup_completion_path
      elsif Current.identity.accounts.one?
        # Single account - go directly there
        root_url(script_name: Current.identity.accounts.first.slug)
      else
        # Multiple accounts - show picker
        session_menu_path
      end
    end
end
```

### Account Selection (Menu)

After authentication, if the user has multiple accounts:

```ruby
# app/controllers/sessions/menus_controller.rb
class Sessions::MenusController < ApplicationController
  disallow_account_scope

  layout "public"

  def show
    @accounts = Current.identity.accounts

    # Auto-redirect if only one account
    if @accounts.one?
      redirect_to root_url(script_name: @accounts.first.slug)
    end
  end
end
```

```erb
<!-- app/views/sessions/menus/show.html.erb -->
<h1>Select an account</h1>

<ul>
  <% @accounts.each do |account| %>
    <li>
      <%= link_to account.name, root_url(script_name: account.slug) %>
    </li>
  <% end %>
</ul>
```

### Magic Link Mailer

```ruby
# app/mailers/magic_link_mailer.rb
class MagicLinkMailer < ApplicationMailer
  def sign_in_instructions(magic_link)
    @magic_link = magic_link
    @code = magic_link.code

    mail(
      to: magic_link.identity.email_address,
      subject: "Your sign-in code: #{@code}"
    )
  end
end
```

---

## Authorization

After authentication, verify the user can access the current account:

```ruby
# app/controllers/concerns/authorization.rb
module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_can_access_account,
      if: -> { Current.account.present? && authenticated? }
  end

  class_methods do
    def allow_unauthorized_access(**options)
      skip_before_action :ensure_can_access_account, **options
    end
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

    def ensure_admin
      head :forbidden unless Current.user&.admin?
    end
end
```

### Application Controller

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
end
```

---

## Background Jobs

Jobs must preserve tenant context. When a job is enqueued, capture `Current.account`. When it runs, restore it.

```ruby
# config/initializers/active_job_extensions.rb

module TenantAwareJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge("account" => @account&.to_gid&.to_s)
  end

  def deserialize(job_data)
    super
    if account_gid = job_data["account"]
      @account = GlobalID::Locator.locate(account_gid)
    end
  end

  def perform_now
    if account.present?
      Current.with_account(account) { super }
    else
      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  prepend TenantAwareJobExtensions
end
```

### How It Works

```ruby
# When enqueued (in a request with Current.account = acme)
NotificationJob.perform_later(user)
# Job serializes: { "account" => "gid://app/Account/abc123", ... }

# When executed (possibly on a different server, later)
# Job deserializes account, then:
Current.with_account(acme) do
  # Your perform method runs here with Current.account set
end
```

### Example Job

```ruby
# app/jobs/notification_job.rb
class NotificationJob < ApplicationJob
  def perform(user, message)
    # Current.account is automatically available!
    user.notifications.create!(
      account: Current.account,
      message: message
    )
  end
end
```

---

## Route Helpers and URL Generation

### Routes Configuration

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Tenant-scoped routes (most of your app)
  root "dashboards#show"

  resources :boards do
    resources :cards
  end

  resources :users

  # Non-tenant routes (authentication, signup)
  resource :session do
    scope module: :sessions do
      resource :magic_link
      resource :menu
    end
  end

  resource :signup do
    scope module: :signups do
      resource :completion
    end
  end
end
```

### URL Generation

Because of `SCRIPT_NAME` manipulation, route helpers work automatically:

```ruby
# In a controller/view within /1234567 context:
boards_path           # => "/1234567/boards"
board_path(@board)    # => "/1234567/boards/abc"
root_path             # => "/1234567/"

# To generate URLs without the account prefix:
new_session_path(script_name: nil)  # => "/session/new"

# To generate URLs for a different account:
root_url(script_name: other_account.slug)  # => "http://app.com/7654321/"
```

### Turbo Streams and Action Cable

For real-time updates, ensure broadcasts include the correct script_name:

```ruby
# config/initializers/tenanting/turbo_streams.rb

module TurboStreamsAccountAware
  extend ActiveSupport::Concern

  class_methods do
    def render_format(format, **rendering)
      if Current.account.present?
        renderer = ApplicationController.renderer.new(script_name: Current.account.slug)
        renderer.render(formats: [format], **rendering)
      else
        super
      end
    end
  end
end

Rails.application.config.after_initialize do
  Turbo::StreamsChannel.prepend TurboStreamsAccountAware
end
```

---

## Common Patterns

### Pattern 1: Default Account Association

Models should automatically set `account_id` from their parent:

```ruby
# app/models/board.rb
class Board < ApplicationRecord
  belongs_to :account, default: -> { creator.account }
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

# app/models/card.rb
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

# app/models/comment.rb
class Comment < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end
```

This creates a hierarchy where `account_id` flows down:

```
Account
  └── Board (account from self)
       └── Card (account from board)
            └── Comment (account from card)
```

### Pattern 2: Account-Scoped Queries

Always scope queries to the current account:

```ruby
# In controllers
def index
  @boards = Current.account.boards.all
end

# Or use a scope
def index
  @boards = Board.where(account: Current.account)
end
```

### Pattern 3: Validating Account Consistency

Ensure related records belong to the same account:

```ruby
class Card < ApplicationRecord
  belongs_to :board

  validate :board_belongs_to_same_account

  private
    def board_belongs_to_same_account
      if board.present? && board.account_id != account_id
        errors.add(:board, "must belong to the same account")
      end
    end
end
```

### Pattern 4: System User for Automated Actions

For background jobs or system operations:

```ruby
class AutoCloseCardsJob < ApplicationJob
  def perform
    # Use system user for automated changes
    Current.user = Current.account.system_user

    Card.stale.find_each(&:close)
  end
end
```

### Pattern 5: Cross-Account Queries (Admin Only)

Rarely needed, but for admin dashboards:

```ruby
class Admin::DashboardController < AdminController
  def show
    Current.without_account do
      @total_accounts = Account.count
      @total_users = User.count
    end
  end
end
```

### Pattern 6: Account-Scoped Framework Tables

Even Rails framework tables should be scoped:

```ruby
# config/initializers/account_scoped_framework_models.rb

Rails.application.config.after_initialize do
  # Scope Active Storage
  ActiveStorage::Blob.class_eval do
    belongs_to :account, optional: true
  end

  ActiveStorage::Attachment.class_eval do
    belongs_to :account, optional: true
    before_create { self.account_id = record.account_id if record.respond_to?(:account_id) }
  end

  # Scope Action Text
  ActionText::RichText.class_eval do
    belongs_to :account, optional: true
    before_create { self.account_id = record.account_id if record.respond_to?(:account_id) }
  end
end
```

---

## Testing

### Test Helper

```ruby
# test/test_helper.rb

class ActiveSupport::TestCase
  # Set up tenant context for tests
  def with_account(account, user: nil)
    Current.with_account(account) do
      if user
        Current.user = user
        Current.identity = user.identity
      end
      yield
    end
  end
end

class ActionDispatch::IntegrationTest
  # Sign in as a user in a specific account
  def sign_in_as(user)
    identity = user.identity
    session = identity.sessions.create!(user_agent: "Test", ip_address: "127.0.0.1")

    cookies[:session_token] = session.signed_id
  end

  # Make requests within an account context
  def within_account(account)
    host! "app.example.com"
    @account_script_name = account.slug
  end

  def get(path, **options)
    super(prepend_account_slug(path), **options)
  end

  def post(path, **options)
    super(prepend_account_slug(path), **options)
  end

  # ... same for put, patch, delete

  private
    def prepend_account_slug(path)
      return path unless @account_script_name
      return path if path.start_with?(@account_script_name)
      "#{@account_script_name}#{path}"
    end
end
```

### Example Tests

```ruby
# test/controllers/boards_controller_test.rb
class BoardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:acme)
    @user = users(:alice)  # Alice is in Acme account

    sign_in_as(@user)
    within_account(@account)
  end

  test "index shows only boards from current account" do
    get boards_path

    assert_response :success

    # Should see Acme's boards
    assert_select "h2", @account.boards.first.name

    # Should NOT see other account's boards
    other_board = accounts(:globex).boards.first
    assert_select "h2", text: other_board.name, count: 0
  end

  test "cannot access board from different account" do
    other_board = accounts(:globex).boards.first

    get board_path(other_board)

    assert_response :not_found
  end
end
```

### Fixture Considerations

```yaml
# test/fixtures/accounts.yml
acme:
  name: Acme Corp
  external_account_id: 1000001

globex:
  name: Globex Industries
  external_account_id: 1000002

# test/fixtures/identities.yml
alice_identity:
  email_address: alice@example.com

# test/fixtures/users.yml
alice:
  account: acme
  identity: alice_identity
  name: Alice
  role: owner

alice_at_globex:
  account: globex
  identity: alice_identity
  name: Alice
  role: member
```

---

## Summary

This multi-tenancy implementation provides:

1. **Complete data isolation** - Every table has `account_id`
2. **Simple URL structure** - `/1234567/boards/...`
3. **Automatic URL generation** - Route helpers just work
4. **Global identity** - One login, multiple accounts
5. **Thread-safe context** - `Current.account`, `Current.user`
6. **Background job support** - Tenant context preserved
7. **Easy local development** - No subdomain configuration

The key insight is using `SCRIPT_NAME` manipulation in middleware to make Rails think it's mounted at the account path. This gives you automatic URL generation without touching any route helpers or view code.

For additional patterns and real-world implementation details, explore the Fizzy codebase:

- `config/initializers/tenanting/` - Middleware and Turbo integration
- `app/models/current.rb` - Current attributes setup
- `app/controllers/concerns/authentication.rb` - Auth implementation
- `app/models/account.rb` - Account model with all associations
