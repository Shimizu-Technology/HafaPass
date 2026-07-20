# frozen_string_literal: true

class Api::V1::Support::NotesController < Api::V1::Support::BaseController
  def index
    notes = SupportNote.includes(:author_user).order(created_at: :desc)
    notes = notes.where(order_id: params[:order_id]) if params[:order_id].present?
    notes = notes.where(ticket_id: params[:ticket_id]) if params[:ticket_id].present?
    notes = notes.where(event_id: params[:event_id]) if params[:event_id].present?
    render json: { notes: notes.limit(100).map { |note| note_json(note) } }
  end

  def create
    note = SupportNote.create!(
      author_user: current_user,
      order_id: params[:order_id],
      ticket_id: params[:ticket_id],
      event_id: params[:event_id],
      body: params[:body]
    )
    AuditLogger.record!(action: "support.note_created", auditable: note, actor: current_user, request: request)
    render json: note_json(note), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def note_json(note)
    {
      id: note.id,
      order_id: note.order_id,
      ticket_id: note.ticket_id,
      event_id: note.event_id,
      body: note.body,
      author: note.author_user.email,
      created_at: note.created_at
    }
  end
end
