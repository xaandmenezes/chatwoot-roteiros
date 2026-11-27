class CreateRyzeAudioTranscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :ryze_audio_transcriptions do |t|
      t.references :attachment, type: :integer, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.integer :status, default: 0, null: false
      t.integer :attempts, default: 0, null: false
      t.datetime :next_attempt_at
      t.text :text
      t.timestamps
      t.index [:status, :next_attempt_at]
    end
  end
end
