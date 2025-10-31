class Card::TouchAllJob < ApplicationJob
  queue_as :backend

  def perform(container)
    container.cards.in_batches(&:touch_all)
  end
end
