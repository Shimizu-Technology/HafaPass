# frozen_string_literal: true

class Api::V1::Me::TicketTransfersController < ApplicationController
  def create
    ticket = current_user.held_tickets.find(params[:ticket_id])
    transfer = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: params[:recipient_email],
      recipient_name: params[:recipient_name], initiated_by: current_user)
    render json: { id: transfer.id, status: transfer.status, recipient_email: transfer.recipient_email,
      expires_at: transfer.expires_at }, status: :created
  rescue TicketTransfers::Manager::TransferError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    ticket = current_user.held_tickets.find(params[:ticket_id])
    transfer = ticket.ticket_transfers.pending.first
    return render json: { error: "Pending transfer not found" }, status: :not_found unless transfer

    TicketTransfers::Manager.cancel!(transfer)
    render json: { status: transfer.status }
  rescue TicketTransfers::Manager::TransferError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def accept
    transfer = TicketTransfers::Manager.accept!(token: params[:token], user: current_user)
    render json: {
      status: transfer.status,
      ticket_id: transfer.ticket_id,
      display_credential: transfer.ticket.display_credential
    }
  rescue TicketTransfers::Manager::TransferError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
