# CSS Architecture and Asset Pipeline

This document provides an in-depth explanation of how Fizzy handles CSS, from how stylesheets are discovered and served by the asset pipeline to the modern CSS patterns used throughout the codebase.

## Overview

Fizzy uses a **zero-config, no-build-step CSS architecture** built on:

1. **Propshaft** - The Rails 8 default asset pipeline (replaces Sprockets)
2. **Native CSS** - No preprocessors (no Sass, PostCSS, or Tailwind)
3. **CSS Cascade Layers** - Explicit specificity control via `@layer`
4. **Modern CSS Features** - Native nesting, `:has()`, `@starting-style`, OKLCH colors

The philosophy: leverage what browsers provide natively rather than adding build complexity.

---

## Asset Pipeline: Propshaft

### How CSS Files Are Discovered

Unlike Sprockets (which required a manifest file with `*= require` directives), **Propshaft automatically serves all CSS files** in the asset paths.

When you use:

```erb
<%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
```

Propshaft generates `<link>` tags for **every `.css` file** in `app/assets/stylesheets/`. There is no manifest file, no explicit imports, no bundling step.

**Key files:**
- `/Users/leo/zDev/GitHub/fizzy/app/views/layouts/shared/_head.html.erb` - Contains the `stylesheet_link_tag`
- `/Users/leo/zDev/GitHub/fizzy/config/initializers/assets.rb` - Asset version configuration

### How It Works

1. Propshaft scans `app/assets/stylesheets/` at startup
2. Each `.css` file gets a digest fingerprint (e.g., `buttons-abc123.css`)
3. `stylesheet_link_tag :app` generates `<link>` tags for all discovered files
4. Files are served directly - no compilation, no bundling

### File Loading Order

Since Propshaft loads **all** CSS files without explicit ordering, Fizzy uses **CSS Cascade Layers** (`@layer`) to control specificity:

```css
/* _global.css - Declares layer order */
@layer reset, base, components, modules, utilities, native, platform;
```

This declaration in `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/_global.css` (note the `_` prefix which makes it load first alphabetically) establishes the precedence:

1. `reset` - CSS reset rules (lowest specificity)
2. `base` - Element defaults (body, a, etc.)
3. `components` - Component styles (.btn, .card, etc.)
4. `modules` - Larger features
5. `utilities` - Utility classes (.flex, .pad, etc.)
6. `native` - Native app adjustments
7. `platform` - Platform-specific styles (iOS, Android)

**Why this matters:** Later layers always win, regardless of selector specificity. A simple `.hidden` in the utilities layer beats a complex `.card .header .title a` in the components layer.

---

## File Organization

```
app/assets/stylesheets/
├── _global.css           # Layer declaration, CSS variables, dark mode
├── reset.css             # CSS reset (@layer reset)
├── base.css              # Element defaults (@layer base)
├── layout.css            # Grid layout (@layer base)
├── utilities.css         # Utility classes (@layer utilities)
│
├── buttons.css           # .btn component (@layer components)
├── cards.css             # .card component (@layer components)
├── inputs.css            # Form controls (@layer components)
├── dialog.css            # Dialog animations (@layer components)
├── popup.css             # Dropdown menus (@layer components)
├── [40+ more files]      # Each component in its own file
│
├── native.css            # Native app overrides (@layer native)
├── ios.css               # iOS platform styles (@layer platform)
├── android.css           # Android platform styles (@layer platform)
│
└── print.css             # Print styles (no layer, uses @media print)
```

### Naming Convention

- `_global.css` - Underscore prefix ensures alphabetical first loading
- Component files use lowercase with hyphens: `card-columns.css`, `rich-text-content.css`
- No manifest file or explicit imports needed

---

## Modern CSS Features

### 1. CSS Cascade Layers (`@layer`)

Every CSS file wraps its content in a layer:

```css
/* buttons.css */
@layer components {
  .btn {
    /* styles */
  }
}

/* utilities.css */
@layer utilities {
  .flex { display: flex; }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/_global.css` (line 1)

### 2. Native CSS Nesting

No Sass required - browsers support nesting natively:

```css
.btn {
  background-color: var(--btn-background);

  &:hover {
    filter: brightness(var(--btn-hover-brightness));
  }

  &[disabled] {
    cursor: not-allowed;
    opacity: 0.3;
  }

  /* Dark mode variant */
  html[data-theme="dark"] & {
    --btn-hover-brightness: 1.25;
  }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/buttons.css`

### 3. CSS Custom Properties (Variables)

The entire design system is built on CSS variables:

```css
:root {
  /* Spacing */
  --inline-space: 1ch;
  --block-space: 1rem;

  /* Typography */
  --text-small: 0.85rem;
  --text-normal: 1rem;

  /* Colors using OKLCH */
  --lch-blue-dark: 57.02% 0.1895 260.46;
  --color-link: oklch(var(--lch-blue-dark));

  /* Component tokens */
  --btn-size: 2.65em;
  --dialog-duration: 150ms;
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/_global.css`

### 4. OKLCH Color Space

Fizzy uses OKLCH for perceptually uniform colors:

```css
:root {
  /* Store LCH triplets as variables */
  --lch-blue-darkest: 26% 0.126 264;
  --lch-blue-darker: 40% 0.166 262;
  --lch-blue-dark: 57.02% 0.1895 260.46;
  --lch-blue-medium: 66% 0.196 257.82;
  --lch-blue-light: 84.04% 0.0719 255.29;

  /* Create colors with oklch() */
  --color-link: oklch(var(--lch-blue-dark));
}
```

**Why OKLCH:**
- Perceptually uniform - equal lightness steps look equal
- Wider P3 color gamut on modern displays
- Easy dark mode - just swap lightness values

### 5. Dark Mode Implementation

Dark mode works by redefining the OKLCH values:

```css
/* Light mode (default) */
:root {
  --lch-ink-darkest: 26% 0.05 264;   /* Dark text */
  --lch-canvas: 100% 0 0;             /* White background */
}

/* Dark mode - explicit choice */
html[data-theme="dark"] {
  --lch-ink-darkest: 96.02% 0.0034 260;  /* Light text */
  --lch-canvas: 20% 0.0195 232.58;        /* Dark background */
}

/* Dark mode - system preference fallback */
@media (prefers-color-scheme: dark) {
  html:not([data-theme]) {
    --lch-ink-darkest: 96.02% 0.0034 260;
    --lch-canvas: 20% 0.0195 232.58;
  }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/_global.css` (lines 261-472)

### 6. `color-mix()` for Dynamic Colors

Generate colors dynamically from base colors:

```css
.card {
  --card-bg-color: color-mix(in srgb, var(--card-color) 4%, var(--color-canvas));
  --card-text-color: color-mix(in srgb, var(--card-color) 75%, var(--color-ink));
  --card-border: 1px solid color-mix(in srgb, var(--card-color) 33%, var(--color-ink-inverted));
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/cards.css` (lines 7-10)

### 7. `:has()` Parent Selector

Style parents based on their children:

```css
/* Button changes when its checkbox is checked */
.btn:has(input:checked) {
  --btn-background: var(--color-ink);
  --btn-color: var(--color-ink-inverted);
}

/* Card changes when it has a closed stamp */
.card:has(.card__closed) {
  --card-color: var(--color-card-complete) !important;
}

/* Hide section when all popup items are hidden */
.popup__section:has(.popup__item[hidden]):not(:has(.popup__item:not([hidden]))) {
  display: none;
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/buttons.css` (line 198)

### 8. `@starting-style` for Entry Animations

Animate elements appearing in the DOM:

```css
.dialog {
  opacity: 0;
  transform: scale(0.2);
  transition: var(--dialog-duration) allow-discrete;
  transition-property: display, opacity, overlay, transform;

  &[open] {
    opacity: 1;
    transform: scale(1);
  }

  @starting-style {
    &[open] {
      opacity: 0;
      transform: scale(0.2);
    }
  }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/dialog.css`

### 9. Container Queries

Size-based responsive design independent of viewport:

```css
.card-columns {
  container-type: inline-size;
}

.cards {
  /* Responsive gap based on container, not viewport */
  --cards-gap: min(1.2cqi, 1.7rem);
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/card-columns.css` (lines 11, 20)

### 10. Logical Properties

RTL-ready by default using logical properties:

```css
.pad-block { padding-block: var(--block-space); }
.pad-inline { padding-inline: var(--inline-space); }
.margin-inline-start { margin-inline-start: var(--inline-space); }

/* Used throughout instead of directional properties */
.card__board-name {
  border-inline-start: 1px solid currentColor;
  margin-inline-start: var(--card-header-space);
  padding-inline-start: var(--card-header-space);
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/utilities.css` (lines 126-170)

### 11. `field-sizing: content`

Inputs that grow with content:

```css
.input--textarea {
  @supports (field-sizing: content) {
    field-sizing: content;
    max-block-size: calc(3lh + (2 * var(--input-padding)));
    min-block-size: calc(1lh + (2 * var(--input-padding)));
  }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/inputs.css` (lines 143-148)

### 12. View Transitions

Named view transitions for smooth navigation:

```css
.tray--pins {
  view-transition-name: tray-pins;
}

::view-transition-group(tray-pins) {
  z-index: 100;
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/trays.css` (lines 342, 514-516)

---

## Component Architecture

### CSS Variable APIs

Components expose customization through variables:

```css
.btn {
  /* Configurable variables with defaults */
  --icon-size: var(--btn-icon-size, 1.3em);
  --btn-border-radius: 99rem;
  --btn-background: var(--btn-background, var(--color-canvas));
  --btn-border-color: var(--btn-border-color, var(--color-ink-light));
  --btn-color: var(--btn-color, var(--color-ink));
  --btn-padding: var(--btn-padding, 0.5em 1.1em);

  /* Use the variables */
  background-color: var(--btn-background);
  border: 1px solid var(--btn-border-color);
  color: var(--btn-color);
  padding: var(--btn-padding);
  border-radius: var(--btn-border-radius);
}

/* Variants override the variables */
.btn--link {
  --btn-background: var(--color-link);
  --btn-color: var(--color-ink-inverted);
}

.btn--negative {
  --btn-background: var(--color-negative);
  --btn-color: var(--color-ink-inverted);
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/buttons.css`

### BEM-Inspired Naming

Components use a pragmatic BEM-like convention:

```css
/* Block */
.card { }

/* Elements (double underscore) */
.card__header { }
.card__body { }
.card__title { }

/* Modifiers (double hyphen) */
.card--notification { }
.card--closed { }
```

But unlike strict BEM:
- Uses `:has()` for parent-aware styling
- Heavy use of CSS variables for theming
- Nesting for related selectors

---

## Icons System

Icons use CSS masks with inline SVG URLs:

```css
.icon {
  background-color: currentColor;
  mask-image: var(--svg);
  mask-position: center;
  mask-repeat: no-repeat;
  mask-size: var(--icon-size, 1em);
}

.icon--add { --svg: url("add.svg"); }
.icon--close { --svg: url("close.svg"); }
.icon--search { --svg: url("search.svg"); }
```

**Why this approach:**
- Icons inherit text color via `currentColor`
- No icon font overhead
- SVGs loaded from asset pipeline with fingerprinting
- Single HTTP request per icon (cached)

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/icons.css`

---

## Platform-Specific Styles

Fizzy supports native iOS/Android apps with platform layers:

```css
@layer native {
  [data-platform~=native] {
    --custom-safe-inset-top: var(--injected-safe-inset-top, env(safe-area-inset-top, 0px));
    --custom-safe-inset-bottom: var(--injected-safe-inset-bottom, env(safe-area-inset-bottom, 0px));

    .hide-on-native {
      display: none;
    }
  }
}

@layer platform {
  [data-platform~=ios] {
    .hide-on-ios {
      display: none;
    }
  }
}
```

**Files:**
- `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/native.css`
- `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/ios.css`
- `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/android.css`

---

## Print Styles

Print styles live outside layers to ensure they apply:

```css
@media print {
  :root {
    --color-ink: black;
    --color-canvas: white;
  }

  .card {
    background: var(--color-canvas);
    box-shadow: none;
    break-inside: avoid;
  }
}
```

**File:** `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/print.css`

---

## Responsive Strategy

Fizzy uses minimal breakpoints with fluid values:

```css
:root {
  /* Fluid padding using clamp */
  --main-padding: clamp(var(--inline-space), 3vw, calc(var(--inline-space) * 3));

  /* Responsive tray sizing */
  --tray-size: clamp(12rem, 25dvw, 24rem);

  /* Responsive text at small viewports */
  @media (max-width: 639px) {
    --text-small: 0.95rem;
    --text-normal: 1.1rem;
  }
}
```

Only 2-3 breakpoints are used:
- `max-width: 639px` - Mobile
- `min-width: 640px` - Desktop
- `max-width: 799px` - Tablet and below

---

## Key Takeaways

1. **No manifest file** - Propshaft discovers CSS files automatically
2. **No build step** - Native CSS is served directly
3. **Layers control specificity** - Not selectors or `!important`
4. **Variables everywhere** - Design tokens for consistency
5. **Modern features** - `:has()`, `@starting-style`, OKLCH, container queries
6. **Component-per-file** - Easy to find and maintain

## Related Files

- `/Users/leo/zDev/GitHub/fizzy/app/assets/stylesheets/_global.css` - Central configuration
- `/Users/leo/zDev/GitHub/fizzy/app/views/layouts/shared/_head.html.erb` - Asset loading
- `/Users/leo/zDev/GitHub/fizzy/docs/guide/css.md` - Additional CSS patterns documentation

## Sources

- [The Asset Pipeline - Ruby on Rails Guides](https://guides.rubyonrails.org/asset_pipeline.html)
- [GitHub - rails/propshaft](https://github.com/rails/propshaft)
- [Propshaft in Rails 8: New Asset Pipeline Library Explained](https://blog.techcompose.com/rails-8-propshaft-asset-pipeline-guide/)
- [Rails Propshaft Guide](https://propshaft-rails.com/)
