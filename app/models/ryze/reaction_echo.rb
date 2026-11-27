class Ryze::ReactionEcho < ApplicationRecord
  self.table_name = 'ryze_reaction_echoes'

  belongs_to :conversation
end
