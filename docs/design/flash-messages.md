# Flash Messages in Fizzy

This document explains the complete flash message system in Fizzy, from how messages are set in controllers to how users see them rendered and dismissed.

## Overview

Fizzy uses a minimalist flash message system built on Rails' standard flash mechanism, enhanced with Turbo for seamless updates. Flash messages appear as toast-style notifications that automatically fade out after a few seconds.

**Key characteristics:**
- Standard Rails flash types: `:notice` and `:alert` (treated identically for display)
- Auto-dismissing via CSS animation (no JavaScript timer needed)
- Turbo Frame integration for AJAX updates
- Custom flash types for special features (`:welcome_letter`, `:magic_link_code`, `:shake`)

## Architecture

```
Controller                    View Layer                    Browser
    |                             |                            |
    |  flash[:notice] = "Saved"   |                            |
    |  or redirect_to ..., notice:|                            |
    |---------------------------->|                            |
    |                             |                            |
    |                     _flash.html.erb                      |
    |                     turbo_frame_tag :flash               |
    |                             |--------------------------->|
    |                             |                            |
    |                             |              CSS animation |
    |                             |              appear-then-fade
    |                             |                            |
    |                             |              animationend  |
    |                             |              event fires   |
    |                             |<---------------------------|
    |                             |                            |
    |                     element-removal                      |
    |                     Stimulus controller                  |
    |                             |--------------------------->|
    |                             |              remove()      |
    |                             |              element gone  |
```

## Setting Flash Messages in Controllers

### Standard redirect with notice/alert

The most common pattern uses Rails' `redirect_to` with the `:notice` or `:alert` options:

```ruby
# From app/controllers/boards_controller.rb
def update
  @board.update! board_params
  redirect_to edit_board_path(@board), notice: "Saved"
end
```

```ruby
# From app/controllers/sessions_controller.rb
def rate_limit_exceeded
  redirect_to new_session_path, alert: "Try again later."
end
```

### Direct flash hash assignment

For cases where you need to set flash before a redirect:

```ruby
# From app/controllers/users/email_addresses_controller.rb
def create
  if identity&.users&.exists?(account: @user.account)
    flash[:alert] = "You already have a user in this account with that email address"
    redirect_to new_user_email_address_path(@user)
  else
    @user.send_email_address_change_confirmation(new_email_address)
  end
end
```

### With Turbo Stream responses

For AJAX responses that need to show flash messages without a full page reload, use the `turbo_stream_flash` helper:

```erb
<%# From app/views/boards/publications/create.turbo_stream.erb %>
<%= turbo_stream.replace([ @board, :publication ], partial: "boards/edit/publication", locals:{ board: @board }) %>
<%= turbo_stream_flash(notice: "Saved") %>
```

## Flash Types

### Standard types: `:notice` and `:alert`

Both are treated identically in the UI - they display the same styled toast message. The distinction is semantic (positive vs negative feedback) but not visual.

```ruby
# These both render the same way:
redirect_to path, notice: "Settings updated"
redirect_to path, alert: "Something went wrong"
```

### Custom flash type: `:welcome_letter`

A boolean flag that triggers a welcome modal after signup completion:

```ruby
# From app/controllers/signups/completions_controller.rb
def create
  @signup = Signup.new(signup_params)
  if @signup.complete
    flash[:welcome_letter] = true
    redirect_to landing_url(script_name: @signup.account.slug)
  end
end
```

Rendered in the layout footer:

```erb
<%# From app/views/layouts/application.html.erb %>
<%= render "layouts/shared/welcome_letter" if flash[:welcome_letter] %>
```

### Custom flash type: `:magic_link_code`

Development-only flash that displays the magic link code for passwordless authentication:

```ruby
# From app/controllers/concerns/authentication/via_magic_link.rb
def serve_development_magic_link(magic_link)
  if Rails.env.development? && magic_link.present?
    flash[:magic_link_code] = magic_link.code
    response.set_header("X-Magic-Link-Code", magic_link.code)
  end
end
```

This is protected from leaking in production:

```ruby
# From app/controllers/concerns/authentication/via_magic_link.rb
def ensure_development_magic_link_not_leaked
  unless Rails.env.development?
    raise "Leaking magic link via flash in #{Rails.env}?" if flash[:magic_link_code].present?
  end
end
```

### Custom flash type: `:shake`

Triggers a shake animation on the magic link input form when an invalid code is entered:

```ruby
# From app/controllers/sessions/magic_links_controller.rb
def invalid_code
  respond_to do |format|
    format.html { redirect_to session_magic_link_path, flash: { shake: true } }
    format.json { render json: { message: "Try another code." }, status: :unauthorized }
  end
end
```

Used in the view to add the shake class:

```erb
<%# From app/views/sessions/magic_links/show.html.erb %>
<div class="panel panel--centered flex flex-column gap-half <%= "shake" if flash[:alert] || flash[:shake] %>">
```

## View Rendering

### The flash partial

The main flash rendering happens in a shared partial:

```erb
<%# app/views/layouts/shared/_flash.html.erb %>
<%= turbo_frame_tag :flash do %>
  <% if notice = flash[:notice] || flash[:alert] %>
    <div class="flash" data-controller="element-removal" data-action="animationend->element-removal#remove">
      <div class="flash__inner shadow">
        <%= notice %>
      </div>
    </div>
  <% end %>
<% end %>
```

**Key details:**
1. Wrapped in `turbo_frame_tag :flash` - enables targeted Turbo Stream updates
2. Checks both `:notice` and `:alert` (first one found is displayed)
3. Uses `element-removal` Stimulus controller for cleanup
4. Listens for `animationend` event to trigger removal

### Layout integration

The flash partial is rendered in both main layouts:

```erb
<%# app/views/layouts/application.html.erb %>
<%= render "layouts/shared/flash" %>
```

```erb
<%# app/views/layouts/public.html.erb %>
<%= render "layouts/shared/flash" %>
```

## Turbo Integration

### The TurboFlash concern

Located at `app/controllers/concerns/turbo_flash.rb`, this concern provides the `turbo_stream_flash` helper:

```ruby
module TurboFlash
  extend ActiveSupport::Concern

  included do
    helper_method :turbo_stream_flash
  end

  private
    def turbo_stream_flash(**flash_options)
      turbo_stream.replace(:flash, partial: "layouts/shared/flash", locals: { flash: flash_options })
    end
end
```

This is included in `ApplicationController`:

```ruby
# From app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include TurboFlash, ViewTransitions
  # ...
end
```

### Usage in Turbo Stream responses

When a controller responds with Turbo Stream format, you can include flash messages that update without a full page reload:

```erb
<%# Example from app/views/boards/entropies/update.turbo_stream.erb %>
<%= turbo_stream.replace([ @board, :entropy ], partial: "boards/edit/auto_close", locals:{ board: @board }) %>
<%= turbo_stream_flash(notice: "Saved") %>
```

The `turbo_stream_flash` helper generates a Turbo Stream `replace` action targeting the `:flash` frame, re-rendering the flash partial with the new message.

## JavaScript: Stimulus Controller

The `element-removal` controller handles removing the flash message from the DOM after the animation completes:

```javascript
// app/javascript/controllers/element_removal_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  remove() {
    this.element.remove()
  }
}
```

This is triggered by the `animationend` event on the flash element:

```html
<div class="flash" data-controller="element-removal" data-action="animationend->element-removal#remove">
```

## CSS Styling

### Flash container

```css
/* app/assets/stylesheets/flash.css */
@layer components {
  .flash {
    display: flex;
    inset-block-start: var(--block-space);
    inset-inline-start: 50%;
    justify-content: center;
    position: fixed;
    transform: translate(-50%);
    z-index: var(--z-flash);
  }

  .flash__inner {
    animation: appear-then-fade 3s 300ms both;
    background-color: var(--flash-background, var(--color-ink));
    border-radius: 4em;
    color: var(--flash-color, var(--color-ink-inverted));
    display: inline-flex;
    font-size: var(--font-size-medium);
    margin: 0 auto;
    padding: 0.7em 1.4em;
  }
}
```

**Key styling decisions:**
- Fixed positioning at top center of viewport
- High z-index (`--z-flash: 40`) to appear above most content
- Pill-shaped with `border-radius: 4em`
- Dark background with light text (inverted from normal content)
- Uses CSS custom properties for theming support

### Animation

```css
/* app/assets/stylesheets/animation.css */
@keyframes appear-then-fade {
  0%,100% { opacity: 0; }
  5%,60%  { opacity: 1; }
}
```

The animation:
1. Starts invisible (0% opacity)
2. Quickly fades in to full opacity (5%)
3. Stays visible until 60% of duration
4. Fades out to invisible (100%)

With a 3-second duration and 300ms delay:
- 300ms: starts animation
- 450ms (300ms + 150ms): fully visible
- 2.1s (300ms + 1.8s): starts fading
- 3.3s (300ms + 3s): animation ends, element removed

### Z-index hierarchy

From `app/assets/stylesheets/_global.css`:

```css
--z-events-column-header: 1;
--z-events-day-header: 3;
--z-popup: 10;
--z-nav: 30;
--z-flash: 40;
--z-tooltip: 50;
--z-bar: 60;
--z-tray: 61;
--z-welcome: 62;
```

Flash messages appear above navigation but below tooltips and the action bar.

### Theme support

The flash uses CSS custom properties that adapt to dark mode:

```css
/* Light mode (default) */
--color-ink: oklch(var(--lch-ink-darkest));        /* dark text/backgrounds */
--color-ink-inverted: oklch(var(--lch-ink-inverted)); /* light text on dark */

/* Dark mode */
html[data-theme="dark"] {
  --lch-ink-darkest: 96.02% 0.0034 260;  /* now light */
  --lch-ink-inverted: var(--lch-black);   /* now dark */
}
```

## Testing Flash Messages

Controller tests can assert flash content:

```ruby
# From test/controllers/notifications/settings_controller_test.rb
test "update settings" do
  patch notifications_settings_url, params: { ... }
  assert_equal "Settings updated", flash[:notice]
end
```

```ruby
# From test/controllers/my/access_tokens_controller_test.rb
test "show with expired token" do
  get my_access_token_url(expired_id)
  assert_equal "Token is no longer visible", flash[:alert]
end
```

```ruby
# From test/controllers/signup/completions_controller_test.rb
test "create sets welcome letter flag" do
  post signup_completion_url, params: { ... }
  assert flash[:welcome_letter]
end
```

## Summary

Fizzy's flash message system is notable for its simplicity:

1. **No distinction between notice/alert** - Both display identically, keeping the UI simple
2. **CSS-driven auto-dismiss** - The animation handles timing; JavaScript just cleans up the DOM
3. **Turbo Frame integration** - The `:flash` frame enables seamless AJAX updates
4. **Custom types for special cases** - `:welcome_letter`, `:magic_link_code`, `:shake` serve specific features
5. **Theme-aware styling** - Automatically adapts to light/dark mode

This design follows Fizzy's "vanilla Rails" philosophy - using standard Rails patterns with minimal JavaScript, letting CSS handle presentation concerns where possible.
