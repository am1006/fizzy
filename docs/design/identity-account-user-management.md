# Identity, Account, and User Management System

This document provides a visual guide through the codebase for understanding how Fizzy handles authentication, account management, user management, and session management.

## Table of Contents

1. [System Overview](#system-overview)
2. [Core Domain Models](#core-domain-models)
3. [Authentication Flow (Magic Link)](#authentication-flow-magic-link)
4. [Account Management](#account-management)
5. [User Management](#user-management)
6. [Session Management](#session-management)
7. [Multi-Tenancy and URL Structure](#multi-tenancy-and-url-structure)
8. [File Reference Index](#file-reference-index)

---

## System Overview

Fizzy uses a **passwordless magic link authentication** system with a **multi-tenant architecture**. The key insight is the separation between:

- **Identity**: A global user tied to an email address (can exist across multiple accounts)
- **Account**: A tenant/organization (the "workspace")
- **User**: The membership relationship between an Identity and an Account

```
                              +------------------+
                              |     Identity     |
                              |  (email-based)   |
                              +--------+---------+
                                       |
              +------------------------+------------------------+
              |                        |                        |
              v                        v                        v
        +-----------+           +-----------+           +-----------+
        |   User    |           |   User    |           |   User    |
        | (Account1)|           | (Account2)|           | (Account3)|
        +-----+-----+           +-----+-----+           +-----+-----+
              |                       |                       |
              v                       v                       v
        +-----------+           +-----------+           +-----------+
        |  Account  |           |  Account  |           |  Account  |
        | (Tenant1) |           | (Tenant2) |           | (Tenant3) |
        +-----------+           +-----------+           +-----------+
```

**One Identity can have multiple Users across different Accounts.**

---

## Core Domain Models

These are the models involved in the identity/account/user system. This document focuses on the flow and routing - explore the model files for implementation details.

### Primary Models

| Model | File | Purpose |
|-------|------|---------|
| `Identity` | `/app/models/identity.rb` | Global user tied to email address |
| `User` | `/app/models/user.rb` | Account membership with role |
| `Account` | `/app/models/account.rb` | Tenant/organization |
| `Session` | `/app/models/session.rb` | Browser session record |
| `MagicLink` | `/app/models/magic_link.rb` | Passwordless auth token |
| `Signup` | `/app/models/signup.rb` | Account creation form object |
| `Current` | `/app/models/current.rb` | Request-scoped attributes |

### Supporting Models

| Model | File | Purpose |
|-------|------|---------|
| `Access` | `/app/models/access.rb` | Board-level access grant |
| `Account::JoinCode` | `/app/models/account/join_code.rb` | Invitation link code |
| `Identity::AccessToken` | `/app/models/identity/access_token.rb` | API access tokens |

### Model Concerns

| Concern | File | Purpose |
|---------|------|---------|
| `Identity::Joinable` | `/app/models/identity/joinable.rb` | Join account logic |
| `Identity::Transferable` | `/app/models/identity/transferable.rb` | Session transfer |
| `User::Role` | `/app/models/user/role.rb` | Role enum and permissions |
| `User::Accessor` | `/app/models/user/accessor.rb` | Board access management |

---

## Authentication Flow (Magic Link)

### Routes

```ruby
# /config/routes.rb (lines 146-152)

resource :session do
  scope module: :sessions do
    resources :transfers
    resource :magic_link
    resource :menu
  end
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /session/new` | `sessions#new` | Login form |
| `POST /session` | `sessions#create` | Request magic link |
| `DELETE /session` | `sessions#destroy` | Logout |
| `GET /session/magic_link` | `sessions/magic_links#show` | Enter code form |
| `POST /session/magic_link` | `sessions/magic_links#create` | Verify code |
| `GET /session/menu` | `sessions/menus#show` | Account switcher |
| `GET /session/transfers/:id` | `sessions/transfers#show` | QR code transfer |
| `PATCH /session/transfers/:id` | `sessions/transfers#update` | Complete transfer |

### Flow Diagram

```
+------------------+     +-------------------+     +-------------------+
|                  |     |                   |     |                   |
|  GET /session/new|---->| User enters email |---->| POST /session     |
|  (Login Form)    |     |                   |     | (Request Magic    |
|                  |     |                   |     |  Link)            |
+------------------+     +-------------------+     +--------+----------+
                                                           |
                                                           v
                         +-------------------+     +-------------------+
                         |                   |     |                   |
                         | Email with code   |<----| MagicLinkMailer   |
                         | sent to user      |     | .sign_in_         |
                         |                   |     | instructions      |
                         +--------+----------+     +-------------------+
                                  |
                                  v
+------------------+     +-------------------+     +-------------------+
|                  |     |                   |     |                   |
| GET /session/    |---->| User enters code  |---->| POST /session/    |
| magic_link       |     | from email        |     | magic_link        |
| (Enter Code Form)|     |                   |     | (Verify Code)     |
+------------------+     +-------------------+     +--------+----------+
                                                           |
                                  +------------------------+
                                  |
                                  v
                         +-------------------+
                         | New Session       |
                         | Created           |
                         |                   |
                         | Redirect to:      |
                         | - Completion (new)|
                         | - Account Menu    |
                         +-------------------+
```

### Controllers

#### `SessionsController` (`/app/controllers/sessions_controller.rb`)

Entry point for authentication. Handles both existing users and new signups.

```ruby
def create
  if identity = Identity.find_by(email_address: email_address)
    sign_in identity                    # Existing user -> send magic link
  elsif Account.accepting_signups?
    sign_up                             # New user -> create identity + magic link
  else
    redirect_to_fake_session_magic_link # Unknown email -> fake magic link (timing attack protection)
  end
end
```

#### `Sessions::MagicLinksController` (`/app/controllers/sessions/magic_links_controller.rb`)

Handles magic link code verification.

```ruby
def create
  if magic_link = MagicLink.consume(code)
    authenticate magic_link
  else
    invalid_code
  end
end
```

Key behavior:
- `MagicLink.consume(code)` finds and destroys the magic link (one-time use)
- After authentication, redirects to completion (new signup) or account menu (existing user)

#### `Sessions::MenusController` (`/app/controllers/sessions/menus_controller.rb`)

Account switcher after login.

```ruby
def show
  @accounts = Current.identity.accounts

  if @accounts.one?
    redirect_to root_url(script_name: @accounts.first.slug)  # Auto-redirect if single account
  end
end
```

#### `Sessions::TransfersController` (`/app/controllers/sessions/transfers_controller.rb`)

QR code session transfer between devices.

### QR Code Routes

QR codes are used for session transfer - allowing users to log in on a new device by scanning a code displayed on an already-authenticated device.

```ruby
# /config/routes.rb (line 136)

resources :qr_codes
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/qr_codes/:id` | `qr_codes#show` | Render QR code SVG |

#### `QrCodesController` (`/app/controllers/qr_codes_controller.rb`)

Renders QR codes as SVG images. The `:id` parameter is a signed message containing the URL to encode.

```ruby
def show
  expires_in 1.year, public: true

  qr_code_svg = RQRCode::QRCode
    .new(QrCodeLink.from_signed(params[:id]).url)
    .as_svg(viewbox: true, fill: :white, color: :black)

  render svg: qr_code_svg
end
```

Key behavior:
- Allows unauthenticated access (the QR code itself is just an image)
- Uses signed message verification to prevent arbitrary URL encoding
- Long cache duration (1 year) since the signed content is immutable

**Models involved:** `QrCodeLink` (`/app/models/qr_code_link.rb`)

The `QrCodeLink` class wraps URL signing/verification:
- `QrCodeLink.new(url).signed` - Generate a signed token for a URL
- `QrCodeLink.from_signed(token).url` - Verify and extract the original URL

This is used by `Sessions::TransfersController` to create secure session transfer links.

### Authentication Concern

The `Authentication` concern (`/app/controllers/concerns/authentication.rb`) is included in `ApplicationController` and provides:

```ruby
before_action :require_account        # Must have account context
before_action :require_authentication # Must be logged in
```

**Helper methods:**
- `authenticated?` - Check if user is logged in
- `start_new_session_for(identity)` - Create new session
- `terminate_session` - Logout
- `resume_session` - Restore session from cookie

**Class methods for controllers:**
- `allow_unauthenticated_access` - Skip authentication requirement
- `require_unauthenticated_access` - Must NOT be logged in
- `disallow_account_scope` - Skip account requirement

### Magic Link Concern

The `Authentication::ViaMagicLink` concern (`/app/controllers/concerns/authentication/via_magic_link.rb`) provides:

```ruby
redirect_to_session_magic_link(magic_link)   # Redirect to code entry
redirect_to_fake_session_magic_link(email)   # Fake redirect (timing protection)
email_address_pending_authentication         # Get email from cookie
```

---

## Account Management

### Routes

```ruby
# /config/routes.rb (lines 4-9)

namespace :account do
  resource :entropy
  resource :join_code
  resource :settings
  resources :exports, only: [ :create, :show ]
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/account/settings` | `account/settings#show` | Account settings page |
| `PATCH /:account/account/settings` | `account/settings#update` | Update account |
| `GET /:account/account/join_code` | `account/join_codes#show` | View invite link |
| `PATCH /:account/account/join_code` | `account/join_codes#update` | Update invite settings |
| `DELETE /:account/account/join_code` | `account/join_codes#destroy` | Reset invite code |

### Signup Routes

```ruby
# /config/routes.rb (lines 154-162)

get "/signup", to: redirect("/signup/new")

resource :signup, only: %i[ new create ] do
  collection do
    scope module: :signups, as: :signup do
      resource :completion, only: %i[ new create ]
    end
  end
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /signup/new` | `signups#new` | Signup form |
| `POST /signup` | `signups#create` | Submit email |
| `GET /signup/completion/new` | `signups/completions#new` | Enter name form |
| `POST /signup/completion` | `signups/completions#create` | Create account |

### Account Creation Flow

```
+------------------+     +-------------------+     +-------------------+
|                  |     |                   |     |                   |
|  GET /signup/new |---->| Enter email       |---->| POST /signup      |
|  (Signup Form)   |     |                   |     | (Create Identity) |
+------------------+     +-------------------+     +--------+----------+
                                                           |
                                                           v
                         +-------------------+     +-------------------+
                         |                   |     |                   |
                         | Verify magic link |<----| Magic link email  |
                         | (same as login)   |     |                   |
                         +--------+----------+     +-------------------+
                                  |
                                  v
+------------------+     +-------------------+     +-------------------+
|                  |     |                   |     |                   |
| GET /signup/     |---->| Enter name        |---->| POST /signup/     |
| completion/new   |     |                   |     | completion        |
| (Name Form)      |     |                   |     | (Create Account)  |
+------------------+     +-------------------+     +--------+----------+
                                                           |
                                                           v
                         +-------------------+
                         | Account created   |
                         | with:             |
                         | - System user     |
                         | - Owner user      |
                         | - Join code       |
                         | - Default board   |
                         +-------------------+
```

### Controllers

#### `SignupsController` (`/app/controllers/signups_controller.rb`)

Handles initial signup with email.

```ruby
def create
  signup = Signup.new(signup_params)
  if signup.valid?(:identity_creation)
    redirect_to_session_magic_link signup.create_identity
  else
    head :unprocessable_entity
  end
end
```

#### `Signups::CompletionsController` (`/app/controllers/signups/completions_controller.rb`)

Handles account creation after email verification.

```ruby
def create
  @signup = Signup.new(signup_params)

  if @signup.complete
    flash[:welcome_letter] = true
    redirect_to landing_url(script_name: @signup.account.slug)
  else
    render :new, status: :unprocessable_entity
  end
end
```

The `Signup#complete` method creates:
1. Account with name derived from user's name
2. System user (for automated actions)
3. Owner user (the person signing up)
4. Join code for invitations
5. Default board template

#### `Account::SettingsController` (`/app/controllers/account/settings_controller.rb`)

Account settings (name, etc.)

#### `Account::JoinCodesController` (`/app/controllers/account/join_codes_controller.rb`)

Manage invite link settings.

### Landing Page

After login or signup completion, users are redirected to the landing page which intelligently routes them to the appropriate destination.

```ruby
# /config/routes.rb (line 164)

resource :landing
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/landing` | `landings#show` | Post-login redirect |

#### `LandingsController` (`/app/controllers/landings_controller.rb`)

Smart redirect after authentication. Preserves flash messages (like welcome letter) across the redirect.

```ruby
def show
  flash.keep(:welcome_letter)

  if Current.user.boards.one?
    redirect_to board_path(Current.user.boards.first)  # Single board -> go directly there
  else
    redirect_to root_path  # Multiple boards -> show activity feed
  end
end
```

Key behavior:
- Preserves `:welcome_letter` flash for new signups (shows welcome modal)
- Users with exactly one board are redirected to that board
- Users with multiple boards (or none) go to the activity feed (root)

**Models involved:** `User`, `Board`

This controller acts as a "smart router" that prevents new users from landing on an empty activity feed.

---

## User Management

### Routes

```ruby
# /config/routes.rb (lines 11-23)

resources :users do
  scope module: :users do
    resource :avatar
    resource :role
    resource :events

    resources :push_subscriptions

    resources :email_addresses, param: :token do
      resource :confirmation, module: :email_addresses
    end
  end
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/users` | `users#index` | List all users |
| `GET /:account/users/:id` | `users#show` | User profile |
| `GET /:account/users/:id/edit` | `users#edit` | Edit user form |
| `PATCH /:account/users/:id` | `users#update` | Update user |
| `DELETE /:account/users/:id` | `users#destroy` | Deactivate user |
| `GET /:account/users/:id/avatar` | `users/avatars#show` | Get user avatar |
| `DELETE /:account/users/:id/avatar` | `users/avatars#destroy` | Remove user avatar |
| `PATCH /:account/users/:id/role` | `users/roles#update` | Change role |
| `POST /:account/users/:id/email_addresses` | `users/email_addresses#create` | Request email change |
| `POST /:account/users/:id/email_addresses/:token/confirmation` | `users/email_addresses/confirmations#create` | Confirm email change |

### Join Code Routes

```ruby
# /config/routes.rb (lines 138-144)

get "join/:code", to: "join_codes#new", as: :join
post "join/:code", to: "join_codes#create"

namespace :users do
  resources :joins
  resources :verifications, only: %i[ new create ]
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/join/:code` | `join_codes#new` | Join page |
| `POST /:account/join/:code` | `join_codes#create` | Process join |
| `GET /:account/users/joins/new` | `users/joins#new` | Setup profile |
| `POST /:account/users/joins` | `users/joins#create` | Save profile |
| `GET /:account/users/verifications/new` | `users/verifications#new` | Verify membership |
| `POST /:account/users/verifications` | `users/verifications#create` | Confirm verification |

### Join Account Flow

```
+---------------------+
| User has invite URL |
| /:account/join/:code|
+----------+----------+
           |
           v
+---------------------+     +---------------------+
| GET /join/:code     |---->| Enter email address |
| (JoinCodesController|     | (new or existing)   |
| #new)               |     |                     |
+---------------------+     +----------+----------+
                                       |
                                       v
+---------------------+     +---------------------+
| POST /join/:code    |---->| Identity.join       |
| (JoinCodesController|     | (account)           |
| #create)            |     | Creates User record |
+---------------------+     +----------+----------+
                                       |
              +------------------------+
              |                        |
              v                        v
    +-----------------+      +-----------------+
    | Already logged  |      | Not logged in   |
    | in as this      |      | or different    |
    | identity?       |      | identity?       |
    +--------+--------+      +--------+--------+
             |                        |
             v                        v
    +-----------------+      +-----------------+
    | User already    |      | Send magic link |
    | setup?          |      | with return_to  |
    +---+-------+-----+      | verification    |
        |       |            +-----------------+
        v       v
    +-------+  +------------------+
    | Yes:  |  | No: Redirect to  |
    | Go to |  | verification     |
    | home  |  | flow             |
    +-------+  +------------------+
```

### User Verification Flow (after joining)

```
+-----------------------+     +-----------------------+
| GET /users/           |---->| "Welcome! You've been |
| verifications/new     |     | added to {account}"   |
| (VerificationsCtrl)   |     | [Continue] button     |
+-----------------------+     +----------+------------+
                                         |
                                         v
+-----------------------+     +-----------------------+
| POST /users/          |---->| User.verify (sets     |
| verifications         |     | verified_at timestamp)|
| (VerificationsCtrl)   |     |                       |
+-----------------------+     +----------+------------+
                                         |
                                         v
+-----------------------+     +-----------------------+
| GET /users/joins/new  |---->| "Set up your profile" |
| (JoinsController)     |     | Name, Avatar fields   |
+-----------------------+     +----------+------------+
                                         |
                                         v
+-----------------------+     +-----------------------+
| POST /users/joins     |---->| User.update! with     |
| (JoinsController)     |     | name and avatar       |
+-----------------------+     +----------+------------+
                                         |
                                         v
                              +-----------------------+
                              | Redirect to landing   |
                              | (home page)           |
                              +-----------------------+
```

### Controllers

#### `UsersController` (`/app/controllers/users_controller.rb`)

CRUD operations on users. Note: `destroy` deactivates rather than deletes.

```ruby
def destroy
  @user.deactivate   # Sets active: false, identity: nil
  ...
end
```

#### `Users::AvatarsController` (`/app/controllers/users/avatars_controller.rb`)

Manages user avatar images. Avatars are stored using Active Storage.

```ruby
def show
  if @user.system?
    redirect_to view_context.image_path("system_user.png")  # System user gets static image
  elsif @user.avatar.attached?
    redirect_to rails_blob_url(@user.avatar_thumbnail, disposition: "inline")  # Stored avatar
  elsif stale? @user, cache_control: cache_control
    render_initials  # Fallback: render SVG with user's initials
  end
end
```

Key behavior:
- System users get a static system image
- Users with uploaded avatars get their stored image (as thumbnail variant)
- Users without avatars get an SVG rendered with their initials
- Only users who `can_change?` another user can delete their avatar

**Models involved:** `User` (with Active Storage attachment)

#### `JoinCodesController` (`/app/controllers/join_codes_controller.rb`)

Processes invite link redemption.

```ruby
def create
  @join_code.redeem_if { |account| @identity.join(account) }
  user = User.active.find_by!(account: @join_code.account, identity: @identity)

  if @identity == Current.identity && user.setup?
    redirect_to landing_url(...)
  elsif @identity == Current.identity
    redirect_to new_users_verification_url(...)
  else
    terminate_session if Current.identity
    redirect_to_session_magic_link ...
  end
end
```

#### `Users::RolesController` (`/app/controllers/users/roles_controller.rb`)

Change user roles (member <-> admin). Only admins can change roles.

```ruby
def role_params
  { role: params.require(:user)[:role].presence_in(%w[ member admin ]) || "member" }
end
```

#### `Users::VerificationsController` (`/app/controllers/users/verifications_controller.rb`)

First step after joining - verifies the user accepted the invitation.

#### `Users::JoinsController` (`/app/controllers/users/joins_controller.rb`)

Profile setup after verification.

### User Roles

Defined in `User::Role` concern:

| Role | Permissions |
|------|-------------|
| `owner` | Full access, cannot be modified by others |
| `admin` | Can manage users, boards, settings |
| `member` | Standard access |
| `system` | Automated user for system actions |

---

## Session Management

### The `Current` Object

`Current` (`/app/models/current.rb`) is an `ActiveSupport::CurrentAttributes` class that holds request-scoped data:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  ...
end
```

**Cascading assignment:**
- Setting `session` automatically sets `identity`
- Setting `identity` (with account context) automatically sets `user`

### Session Cookie

Sessions are stored in signed cookies:

```ruby
cookies.signed.permanent[:session_token] = {
  value: session.signed_id,
  httponly: true,
  same_site: :lax
}
```

### My Menu Routes

```ruby
# /config/routes.rb (lines 166-172)

namespace :my do
  resource :identity, only: :show
  resources :access_tokens
  resources :pins
  resource :timezone
  resource :menu
end
```

| Route | Controller#Action | Purpose |
|-------|-------------------|---------|
| `GET /:account/my/identity` | `my/identities#show` | View identity info |
| `GET /:account/my/access_tokens` | `my/access_tokens#index` | List API tokens |
| `POST /:account/my/access_tokens` | `my/access_tokens#create` | Create API token |
| `DELETE /:account/my/access_tokens/:id` | `my/access_tokens#destroy` | Revoke API token |
| `PATCH /:account/my/timezone` | `my/timezones#update` | Update user timezone |
| `GET /:account/my/menu` | `my/menus#show` | User dropdown menu |

### Timezone Controller

#### `My::TimezonesController` (`/app/controllers/my/timezones_controller.rb`)

Updates the current user's timezone preference.

```ruby
def update
  Current.user.settings.update!(timezone_name: timezone_param)
end
```

**Models involved:** `User::Settings` (`/app/models/user/settings.rb`)

The timezone setting is stored in `User::Settings#timezone_name` and used throughout the application for displaying dates/times in the user's local time. The `User::Settings#timezone` method returns an `ActiveSupport::TimeZone` object, defaulting to UTC if no timezone is set.

### API Authentication

In addition to session cookies, Fizzy supports Bearer token authentication:

```ruby
# In Authentication concern
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

---

## Multi-Tenancy and URL Structure

### URL Pattern

All tenant-scoped URLs are prefixed with the account's external ID:

```
/1234567/boards
/1234567/cards/abc123
/1234567/users
```

The ID is a 7+ digit number derived from `Account#external_account_id`.

### AccountSlug Middleware

The `AccountSlug::Extractor` middleware (`/config/initializers/tenanting/account_slug.rb`) extracts the account from the URL:

```ruby
def call(env)
  request = ActionDispatch::Request.new(env)

  if request.path_info =~ PATH_INFO_MATCH
    # Move account prefix from PATH_INFO to SCRIPT_NAME
    request.engine_script_name = request.script_name = $1
    request.path_info = $'.empty? ? "/" : $'

    env["fizzy.external_account_id"] = AccountSlug.decode($2)
  end

  # Set Current.account for the request
  if env["fizzy.external_account_id"]
    account = Account.find_by(external_account_id: ...)
    Current.with_account(account) { @app.call env }
  else
    Current.without_account { @app.call env }
  end
end
```

**Key insight:** The middleware makes Rails think the app is "mounted" at the account prefix, so routes don't need namespacing.

### URL Generation

To generate URLs with the account prefix:

```ruby
# Use script_name option
root_url(script_name: account.slug)
# => "http://fizzy.localhost:3006/1234567/"

# For routes without account scope
session_menu_path(script_name: nil)
# => "/session/menu"
```

---

## File Reference Index

### Controllers

| File | Purpose |
|------|---------|
| `/app/controllers/sessions_controller.rb` | Login/logout |
| `/app/controllers/sessions/magic_links_controller.rb` | Magic link verification |
| `/app/controllers/sessions/menus_controller.rb` | Account switcher |
| `/app/controllers/sessions/transfers_controller.rb` | QR session transfer |
| `/app/controllers/signups_controller.rb` | Initial signup |
| `/app/controllers/signups/completions_controller.rb` | Account creation |
| `/app/controllers/users_controller.rb` | User CRUD |
| `/app/controllers/users/avatars_controller.rb` | User avatar management |
| `/app/controllers/users/roles_controller.rb` | Role changes |
| `/app/controllers/users/joins_controller.rb` | Profile setup |
| `/app/controllers/users/verifications_controller.rb` | Join verification |
| `/app/controllers/users/email_addresses_controller.rb` | Email change request |
| `/app/controllers/users/email_addresses/confirmations_controller.rb` | Email change confirm |
| `/app/controllers/join_codes_controller.rb` | Process invite links |
| `/app/controllers/account/settings_controller.rb` | Account settings |
| `/app/controllers/account/join_codes_controller.rb` | Manage invite settings |
| `/app/controllers/my/identities_controller.rb` | View identity |
| `/app/controllers/my/access_tokens_controller.rb` | API tokens |
| `/app/controllers/my/timezones_controller.rb` | User timezone preference |
| `/app/controllers/my/menus_controller.rb` | User menu |
| `/app/controllers/qr_codes_controller.rb` | QR code image generation |
| `/app/controllers/landings_controller.rb` | Post-login redirect |

### Concerns

| File | Purpose |
|------|---------|
| `/app/controllers/concerns/authentication.rb` | Session management |
| `/app/controllers/concerns/authentication/via_magic_link.rb` | Magic link helpers |
| `/app/controllers/concerns/authorization.rb` | Access control |

### Models

| File | Purpose |
|------|---------|
| `/app/models/identity.rb` | Global user |
| `/app/models/user.rb` | Account membership |
| `/app/models/user/settings.rb` | User preferences (timezone, notifications) |
| `/app/models/account.rb` | Tenant |
| `/app/models/session.rb` | Browser session |
| `/app/models/magic_link.rb` | Auth token |
| `/app/models/signup.rb` | Signup form object |
| `/app/models/current.rb` | Request context |
| `/app/models/access.rb` | Board access |
| `/app/models/account/join_code.rb` | Invite codes |
| `/app/models/identity/access_token.rb` | API tokens |
| `/app/models/qr_code_link.rb` | QR code URL signing/verification |

### Configuration

| File | Purpose |
|------|---------|
| `/config/routes.rb` | Route definitions |
| `/config/initializers/tenanting/account_slug.rb` | Multi-tenancy middleware |

### Helpers

| File | Purpose |
|------|---------|
| `/app/helpers/login_helper.rb` | Login/logout URL helpers |
