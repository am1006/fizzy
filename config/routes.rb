Rails.application.routes.draw do
  resource :first_run

  resource :account do
    scope module: :accounts do
      resource :join_code
      resources :users
    end
  end

  resources :collections do
    scope module: :collections do
      resource :subscriptions
      resource :workflow, only: :update
      resource :involvement
    end

    resources :cards
  end

  resources :cards do
    scope module: :cards do
      resource :engagement
      resource :image
      resource :pin
      resource :closure
      resource :publish
      resource :reading
      resource :recover
      resource :watch
      resource :goldness

      resources :assignments
      resources :boosts
      resources :stagings
      resources :taggings

      resources :comments do
        resources :reactions, module: :comments
      end
    end
  end

  namespace :cards do
    resources :previews
  end


  resources :notifications, only: :index
  namespace :notifications do
    resource :tray, only: :show
    resource :mark_all_read, only: :create
    resources :mark_read, only: :create
    resource :settings, only: :show
  end

  resources :notifications do
    member do
      post :mark_read
    end
  end

  resources :filters

  resources :events, only: :index
  namespace :events do
    resources :days
  end

  resources :workflows do
    resources :stages, module: :workflows
  end

  resources :uploads, only: :create
  get "/u/*slug" => "uploads#show", as: :upload

  resource :terminal, only: [ :show, :edit ]


  resources :qr_codes
  get "join/:join_code", to: "users#new", as: :join
  post "join/:join_code", to: "users#create"

  resource :session do
    scope module: "sessions" do
      resources :transfers, only: %i[ show update ]
    end
  end

  resources :users do
    scope module: :users do
      resource :avatar
    end
  end

  namespace :my do
    resources :pins
  end


  resolve "Card" do |card, options|
    route_for :collection_card, card.collection, card, options
  end

  resolve "Comment" do |comment, options|
    options[:anchor] = ActionView::RecordIdentifier.dom_id(comment)
    route_for :collection_card, comment.card.collection, comment.card, options
  end


  get "up", to: "rails/health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest


  root "events#index"
end
