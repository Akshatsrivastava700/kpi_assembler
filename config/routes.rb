# frozen_string_literal: true

KPIAssembler::Engine.routes.draw do
  root "workspace#show"

  mount KPIAssembler::AssetServer.new => "/assets"

  namespace :api do
    namespace :v1 do
      get "health", to: "workspace#health"
      match "discover", to: "workspace#discover", via: %i[get post]
      post "certify", to: "workspace#certify"
      get "pack", to: "workspace#pack"
      get "integration", to: "workspace#integration"
    end
  end
end
