// Generated from the real API services (PayoutStatement, AdminPayoutDueList)
// for fictional events; regenerate rather than hand-edit amounts.

export const salesOpen = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "published",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-01-30T00:00:00.000Z",
  "status": "sales_open",
  "status_label": "Sales open",
  "schedule": {
    "ended": false,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -3400,
          "note": "Your share of refunds. Buyers got back $36.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 930100
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 894508
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [],
      "total_label": "Total to be sent to you",
      "total_cents": 894508
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 930100,
    "net_proceeds_cents": 894508,
    "reserve_held_cents": 0,
    "reserve_released_cents": 0,
    "available_cents": 894508,
    "transferred_cents": 0,
    "in_progress_cents": 0,
    "balance_remaining_cents": 894508,
    "still_to_come_cents": 894508,
    "buyer_paid_fees_cents": 60000,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 894508
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $600.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer."
  ],
  "transfers": [],
  "payout": null
}

export const waitingForPayout = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-01-31T23:00:00.000Z",
  "status": "waiting_for_payout",
  "status_label": "Waiting for payout",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -3400,
          "note": "Your share of refunds. Buyers got back $36.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 930100
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 894508
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [],
      "total_label": "Total to be sent to you",
      "total_cents": 894508
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 930100,
    "net_proceeds_cents": 894508,
    "reserve_held_cents": 0,
    "reserve_released_cents": 0,
    "available_cents": 894508,
    "transferred_cents": 0,
    "in_progress_cents": 0,
    "balance_remaining_cents": 894508,
    "still_to_come_cents": 894508,
    "buyer_paid_fees_cents": 60000,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 894508
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $600.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer.",
    "HåfaPass sends the bank transfer within 2–3 business days after the event (by Feb 3, 2027)."
  ],
  "transfers": [],
  "payout": null
}

export const reserveHeld = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-02-01T01:00:00.000Z",
  "status": "reserve_held",
  "status_label": "Paid — reserve held until Mar 1, 2027",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -3400,
          "note": "Your share of refunds. Buyers got back $36.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 930100
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 894508
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -89451,
          "note": "Held back for 30 days in case of chargebacks (about 10% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 805057
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 930100,
    "net_proceeds_cents": 894508,
    "reserve_held_cents": 89451,
    "reserve_released_cents": 0,
    "available_cents": 805057,
    "transferred_cents": 805057,
    "in_progress_cents": 0,
    "balance_remaining_cents": 0,
    "still_to_come_cents": 89451,
    "buyer_paid_fees_cents": 60000,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [
      {
        "label": "Balance after transfers, not counting the reserve",
        "amount_cents": 0,
        "note": null
      },
      {
        "label": "Reserve still held",
        "amount_cents": 89451,
        "note": "Comes back to you on Mar 1, 2027, less any later refunds or chargebacks."
      }
    ],
    "total_label": "Still to come",
    "total_cents": 89451
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $600.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer."
  ],
  "transfers": [
    {
      "id": 36,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 805057,
      "withheld_cents": 0,
      "sent_cents": 805057,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "4321",
      "reference": "TRF-20270201-07",
      "statement_version": 1,
      "counted_cents": -805057
    }
  ],
  "payout": null
}

export const payoutReceipt = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-02-01T01:00:00.000Z",
  "status": "reserve_held",
  "status_label": "Paid — reserve held until Mar 1, 2027",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -3400,
          "note": "Your share of refunds. Buyers got back $36.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 930100
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 894508
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -89451,
          "note": "Held back for 30 days in case of chargebacks (about 10% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 805057
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 930100,
    "net_proceeds_cents": 894508,
    "reserve_held_cents": 89451,
    "reserve_released_cents": 0,
    "available_cents": 805057,
    "transferred_cents": 805057,
    "in_progress_cents": 0,
    "balance_remaining_cents": 0,
    "still_to_come_cents": 89451,
    "buyer_paid_fees_cents": 60000,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [
      {
        "label": "Balance after transfers, not counting the reserve",
        "amount_cents": 0,
        "note": null
      },
      {
        "label": "Reserve still held",
        "amount_cents": 89451,
        "note": "Comes back to you on Mar 1, 2027, less any later refunds or chargebacks."
      }
    ],
    "total_label": "Still to come",
    "total_cents": 89451
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $600.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer."
  ],
  "transfers": [
    {
      "id": 36,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 805057,
      "withheld_cents": 0,
      "sent_cents": 805057,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "4321",
      "reference": "TRF-20270201-07",
      "statement_version": 1,
      "counted_cents": -805057
    }
  ],
  "payout": {
    "id": 36,
    "status": "paid",
    "status_label": "Sent",
    "method": "bank_transfer",
    "amount_cents": 805057,
    "withheld_cents": 0,
    "sent_cents": 805057,
    "requested_on": "2027-02-01",
    "sent_on": "2027-02-01",
    "bank_last4": "4321",
    "reference": "TRF-20270201-07",
    "statement_version": 1,
    "version": {
      "version": 1,
      "finalized_at": "2027-01-31T23:00:00.000Z",
      "net_proceeds_cents": 894508,
      "reserve_held_cents": 89451,
      "available_cents": 805057,
      "previously_sent_cents": 0
    }
  }
}

export const reserveReleased = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-02-28T23:00:00.000Z",
  "status": "waiting_for_payout",
  "status_label": "Waiting for payout",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": true
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -5100,
          "note": "Your share of refunds. Buyers got back $54.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 928400
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        },
        {
          "label": "Chargebacks",
          "amount_cents": -5200,
          "note": "Card payments a buyer's bank took back after a dispute was lost."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 887608
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -89451,
          "note": "Held back for 30 days in case of chargebacks (about 10% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        },
        {
          "label": "Reserve released",
          "amount_cents": 89451,
          "note": "The reserve came back to you. Chargebacks above were taken from it before it was sent."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 887608
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 928400,
    "net_proceeds_cents": 887608,
    "reserve_held_cents": 0,
    "reserve_released_cents": 89451,
    "available_cents": 887608,
    "transferred_cents": 805057,
    "in_progress_cents": 0,
    "balance_remaining_cents": 82551,
    "still_to_come_cents": 82551,
    "buyer_paid_fees_cents": 59900,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 82551
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $599.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer."
  ],
  "transfers": [
    {
      "id": 36,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 805057,
      "withheld_cents": 0,
      "sent_cents": 805057,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "4321",
      "reference": "TRF-20270201-07",
      "statement_version": 1,
      "counted_cents": -805057
    }
  ],
  "payout": null
}

export const coveredRefund = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-02-09T23:00:00.000Z",
  "status": "reserve_held",
  "status_label": "Paid — reserve held until Mar 1, 2027",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -5100,
          "note": "Your share of refunds. Buyers got back $54.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 928400
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 892808
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -89451,
          "note": "Held back for 30 days in case of chargebacks (about 10% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 803357
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 928400,
    "net_proceeds_cents": 892808,
    "reserve_held_cents": 89451,
    "reserve_released_cents": 0,
    "available_cents": 803357,
    "transferred_cents": 805057,
    "in_progress_cents": 0,
    "balance_remaining_cents": -1700,
    "still_to_come_cents": 87751,
    "buyer_paid_fees_cents": 59900,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [
      {
        "label": "Balance after transfers, not counting the reserve",
        "amount_cents": -1700,
        "note": null
      },
      {
        "label": "Reserve still held",
        "amount_cents": 89451,
        "note": "Comes back to you on Mar 1, 2027, less any later refunds or chargebacks."
      }
    ],
    "total_label": "Still to come",
    "total_cents": 87751
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $599.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer.",
    "Refunds or chargebacks after your payout ($17.00) come out of your $894.51 reserve. You will get the remaining $877.51 when it is released."
  ],
  "transfers": [
    {
      "id": 36,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 805057,
      "withheld_cents": 0,
      "sent_cents": 805057,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "4321",
      "reference": "TRF-20270201-07",
      "statement_version": 1,
      "counted_cents": -805057
    }
  ],
  "payout": null
}

export const finalPaid = {
  "event": {
    "id": 40,
    "title": "Island Open Exhibition",
    "slug": "island-open-exhibition",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 45,
    "name": "Fictional Grappling League"
  },
  "currency": "USD",
  "generated_at": "2027-03-01T01:00:00.000Z",
  "status": "final",
  "status_label": "Final",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": true
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 415,
      "gross_cents": 705500,
      "discount_cents": 0,
      "proceeds_cents": 705500
    },
    {
      "name": "Child spectator",
      "quantity": 190,
      "gross_cents": 228000,
      "discount_cents": 0,
      "proceeds_cents": 228000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 933500,
          "note": "Face value of every ticket and add-on sold, before discounts."
        },
        {
          "label": "Refunds",
          "amount_cents": -5100,
          "note": "Your share of refunds. Buyers got back $54.00 in total, including fees returned to them."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 928400
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -30492,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Door cash you collected",
          "amount_cents": -5100,
          "note": "You already have this cash, so it is not part of the bank transfer."
        },
        {
          "label": "Chargebacks",
          "amount_cents": -5200,
          "note": "Card payments a buyer's bank took back after a dispute was lost."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 887608
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -89451,
          "note": "Held back for 30 days in case of chargebacks (about 10% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        },
        {
          "label": "Reserve released",
          "amount_cents": 89451,
          "note": "The reserve came back to you. Chargebacks above were taken from it before it was sent."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 887608
    }
  ],
  "totals": {
    "gross_cents": 933500,
    "ticket_proceeds_cents": 928400,
    "net_proceeds_cents": 887608,
    "reserve_held_cents": 0,
    "reserve_released_cents": 89451,
    "available_cents": 887608,
    "transferred_cents": 887608,
    "in_progress_cents": 0,
    "balance_remaining_cents": 0,
    "still_to_come_cents": 0,
    "buyer_paid_fees_cents": 59900,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 5100
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 0
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $599.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Door cash ($51.00) stays with you and is not included in any bank transfer."
  ],
  "transfers": [
    {
      "id": 36,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 805057,
      "withheld_cents": 0,
      "sent_cents": 805057,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "4321",
      "reference": "TRF-20270201-07",
      "statement_version": 1,
      "counted_cents": -805057
    },
    {
      "id": 37,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 82551,
      "withheld_cents": 0,
      "sent_cents": 82551,
      "requested_on": "2027-03-01",
      "sent_on": "2027-03-01",
      "bank_last4": "4321",
      "reference": "TRF-20270301-02",
      "statement_version": 2,
      "counted_cents": -82551
    }
  ],
  "payout": null
}

export const finalNegative = {
  "event": {
    "id": 42,
    "title": "Fictional Night Market Showcase",
    "slug": "fictional-night-market-showcase",
    "status": "completed",
    "starts_at": "2027-01-29T23:00:00.000Z",
    "ends_at": "2027-01-30T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 47,
    "name": "Example Community Arts Council"
  },
  "currency": "USD",
  "generated_at": "2027-03-01T23:00:00.000Z",
  "status": "final",
  "status_label": "Final",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-30",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-01",
    "reserve_released": true
  },
  "sales_by_ticket": [
    {
      "name": "Adult spectator",
      "quantity": 6,
      "gross_cents": 10200,
      "discount_cents": 0,
      "proceeds_cents": 10200
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 10200,
          "note": "Face value of every ticket and add-on sold, before discounts."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 10200
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -360,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        },
        {
          "label": "Chargebacks",
          "amount_cents": -7200,
          "note": "Card payments a buyer's bank took back after a dispute was lost."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 2640
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [
        {
          "label": "Reserve held",
          "amount_cents": -984,
          "note": "Held back for 30 days in case of chargebacks (about 37% of the net proceeds HåfaPass holds for you). Release date: Mar 1, 2027."
        },
        {
          "label": "Reserve released",
          "amount_cents": 984,
          "note": "The reserve came back to you. Chargebacks above were taken from it before it was sent."
        }
      ],
      "total_label": "Total to be sent to you",
      "total_cents": 2640
    }
  ],
  "totals": {
    "gross_cents": 10200,
    "ticket_proceeds_cents": 10200,
    "net_proceeds_cents": 2640,
    "reserve_held_cents": 0,
    "reserve_released_cents": 984,
    "available_cents": 2640,
    "transferred_cents": 8856,
    "in_progress_cents": 0,
    "balance_remaining_cents": -6216,
    "still_to_come_cents": -6216,
    "buyer_paid_fees_cents": 600,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 0
  },
  "closing": {
    "lines": [],
    "total_label": "You owe",
    "total_cents": -6216
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "Buyers paid $6.00 in HåfaPass fees on top of ticket prices. That was never part of your proceeds.",
    "Chargebacks or refunds after your payout mean you owe $62.16. HåfaPass takes it from your next payout."
  ],
  "transfers": [
    {
      "id": 38,
      "status": "paid",
      "status_label": "Sent",
      "method": "bank_transfer",
      "amount_cents": 8856,
      "withheld_cents": 0,
      "sent_cents": 8856,
      "requested_on": "2027-02-01",
      "sent_on": "2027-02-01",
      "bank_last4": "7788",
      "reference": "TRF-20270201-11",
      "statement_version": 1,
      "counted_cents": -8856
    }
  ],
  "payout": null
}

export const zeroSales = {
  "event": {
    "id": 43,
    "title": "Fictional Empty Hall Rehearsal",
    "slug": "fictional-empty-hall-rehearsal",
    "status": "completed",
    "starts_at": "2026-12-31T23:00:00.000Z",
    "ends_at": "2027-01-01T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 48,
    "name": "Example Org"
  },
  "currency": "USD",
  "generated_at": "2027-02-04T23:00:00.000Z",
  "status": "final",
  "status_label": "Final",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-01",
    "transfer_expected_by": "2027-01-06",
    "reserve_release_on": "2027-01-31",
    "reserve_released": false
  },
  "sales_by_ticket": [],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 0,
          "note": "Face value of every ticket and add-on sold, before discounts."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 0
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [],
      "total_label": "Net proceeds",
      "total_cents": 0
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [],
      "total_label": "Total to be sent to you",
      "total_cents": 0
    }
  ],
  "totals": {
    "gross_cents": 0,
    "ticket_proceeds_cents": 0,
    "net_proceeds_cents": 0,
    "reserve_held_cents": 0,
    "reserve_released_cents": 0,
    "available_cents": 0,
    "transferred_cents": 0,
    "in_progress_cents": 0,
    "balance_remaining_cents": 0,
    "still_to_come_cents": 0,
    "buyer_paid_fees_cents": 0,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 0
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 0
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [],
  "transfers": [],
  "payout": null
}

export const hugeAmounts = {
  "event": {
    "id": 44,
    "title": "Fictional Pacific Grand Championship Finals — Absolute Division, Masters, Juniors and Kids Brackets, Day 1 of 3 (Spectator Admission)",
    "slug": "fictional-pacific-grand-championship-finals-absolute-division-masters-jun",
    "status": "completed",
    "starts_at": "2027-01-30T23:00:00.000Z",
    "ends_at": "2027-01-31T08:00:00.000Z",
    "timezone": "Pacific/Guam",
    "multi_day": false
  },
  "organization": {
    "id": 49,
    "name": "Fictional Inter-Island Brazilian Jiu-Jitsu and Grappling Federation of the Western Pacific Region 🥋"
  },
  "currency": "USD",
  "generated_at": "2027-02-04T23:00:00.000Z",
  "status": "waiting_for_payout",
  "status_label": "Waiting for payout",
  "schedule": {
    "ended": true,
    "ended_on": "2027-01-31",
    "transfer_expected_by": "2027-02-03",
    "reserve_release_on": "2027-03-02",
    "reserve_released": false
  },
  "sales_by_ticket": [
    {
      "name": "Championship floor table for ten guests — premium courtside seating with catering",
      "quantity": 10,
      "gross_cents": 100000000,
      "discount_cents": 0,
      "proceeds_cents": 100000000
    }
  ],
  "sections": [
    {
      "key": "proceeds",
      "title": "Ticket sales",
      "lines": [
        {
          "label": "Ticket sales",
          "amount_cents": 100000000,
          "note": "Face value of every ticket and add-on sold, before discounts."
        }
      ],
      "total_label": "Your ticket proceeds",
      "total_cents": 100000000
    },
    {
      "key": "deductions",
      "title": "Costs and adjustments",
      "lines": [
        {
          "label": "Card processing",
          "amount_cents": -2900000,
          "note": "Stripe's card processing cost on orders where it comes out of your proceeds."
        }
      ],
      "total_label": "Net proceeds",
      "total_cents": 97100000
    },
    {
      "key": "reserve",
      "title": "Chargeback reserve",
      "lines": [],
      "total_label": "Total to be sent to you",
      "total_cents": 97100000
    }
  ],
  "totals": {
    "gross_cents": 100000000,
    "ticket_proceeds_cents": 100000000,
    "net_proceeds_cents": 97100000,
    "reserve_held_cents": 0,
    "reserve_released_cents": 0,
    "available_cents": 97100000,
    "transferred_cents": 0,
    "in_progress_cents": 0,
    "balance_remaining_cents": 97100000,
    "still_to_come_cents": 97100000,
    "buyer_paid_fees_cents": 0,
    "processing_covered_by_hafapass_cents": 0,
    "door_cash_cents": 0
  },
  "closing": {
    "lines": [],
    "total_label": "Still to come",
    "total_cents": 97100000
  },
  "reconciles": true,
  "difference_cents": 0,
  "contradictions": [],
  "notes": [
    "HåfaPass sends the bank transfer within 2–3 business days after the event (by Feb 3, 2027)."
  ],
  "transfers": [],
  "payout": null
}

export const dueFirst = {
  "generated_at": "2027-01-31T23:00:00.000Z",
  "rules": {
    "transfer_business_days": "2–3",
    "reserve_percent": 10,
    "reserve_days": 30,
    "timezone": "Pacific/Guam"
  },
  "counts": {
    "overdue": 0,
    "due": 1,
    "upcoming": 0
  },
  "transfers": [
    {
      "event": {
        "id": 40,
        "title": "Island Open Exhibition",
        "slug": "island-open-exhibition",
        "status": "completed",
        "ended_at": "2027-01-30T08:00:00.000Z",
        "timezone": "Pacific/Guam"
      },
      "organization": {
        "id": 45,
        "name": "Fictional Grappling League"
      },
      "next_step": "hold_reserve",
      "next_step_label": "Hold the reserve",
      "blocker": null,
      "actions": [
        "hold_reserve",
        "finalize_statement"
      ],
      "ended_on": "2027-01-30",
      "transfer_earliest_on": "2027-02-02",
      "transfer_due_on": "2027-02-03",
      "reserve_release_on": "2027-03-01",
      "due_on": "2027-02-03",
      "due_state": "due",
      "overdue_business_days": 0,
      "net_proceeds_cents": 894508,
      "custodial_net_cents": 894508,
      "suggested_reserve_cents": 89451,
      "reserve_held_cents": 0,
      "reserve_released_cents": 0,
      "paid_cents": 0,
      "in_flight_cents": 0,
      "owed_cents": 894508,
      "after_release_cents": 894508,
      "reserve_release_due": false,
      "reserve_released_on": null,
      "reserve_skipped": false,
      "payout_account_ready": true,
      "settlement": null,
      "in_flight_payout": null,
      "currency": "usd"
    }
  ],
  "reserves": []
}

export const dueRelease = {
  "generated_at": "2027-02-28T23:00:00.000Z",
  "rules": {
    "transfer_business_days": "2–3",
    "reserve_percent": 10,
    "reserve_days": 30,
    "timezone": "Pacific/Guam"
  },
  "counts": {
    "overdue": 1,
    "due": 1,
    "upcoming": 0
  },
  "transfers": [
    {
      "event": {
        "id": 41,
        "title": "Fictional Beach Volleyball Cup — Women's Open Division Finals and Awards Night",
        "slug": "fictional-beach-volleyball-cup-women-s-open-division-finals-and-awards-ni",
        "status": "completed",
        "ended_at": "2027-01-22T08:00:00.000Z",
        "timezone": "Pacific/Guam"
      },
      "organization": {
        "id": 46,
        "name": "Example Sports Association of the Northern Pacific Islands"
      },
      "next_step": "hold_reserve",
      "next_step_label": "Hold the reserve",
      "blocker": null,
      "actions": [
        "hold_reserve",
        "finalize_statement"
      ],
      "ended_on": "2027-01-22",
      "transfer_earliest_on": "2027-01-26",
      "transfer_due_on": "2027-01-27",
      "reserve_release_on": "2027-02-21",
      "due_on": "2027-01-27",
      "due_state": "overdue",
      "overdue_business_days": 21,
      "net_proceeds_cents": 65700,
      "custodial_net_cents": 65700,
      "suggested_reserve_cents": 6570,
      "reserve_held_cents": 0,
      "reserve_released_cents": 0,
      "paid_cents": 0,
      "in_flight_cents": 0,
      "owed_cents": 65700,
      "after_release_cents": 65700,
      "reserve_release_due": true,
      "reserve_released_on": null,
      "reserve_skipped": false,
      "payout_account_ready": true,
      "settlement": null,
      "in_flight_payout": null,
      "currency": "usd"
    }
  ],
  "reserves": [
    {
      "event": {
        "id": 40,
        "title": "Island Open Exhibition",
        "slug": "island-open-exhibition",
        "status": "completed",
        "ended_at": "2027-01-30T08:00:00.000Z",
        "timezone": "Pacific/Guam"
      },
      "organization": {
        "id": 45,
        "name": "Fictional Grappling League"
      },
      "next_step": "release_reserve",
      "next_step_label": "Release the reserve",
      "blocker": null,
      "actions": [
        "release_reserve"
      ],
      "ended_on": "2027-01-30",
      "transfer_earliest_on": "2027-02-02",
      "transfer_due_on": "2027-02-03",
      "reserve_release_on": "2027-03-01",
      "due_on": "2027-03-01",
      "due_state": "due",
      "overdue_business_days": 0,
      "net_proceeds_cents": 887608,
      "custodial_net_cents": 887608,
      "suggested_reserve_cents": null,
      "reserve_held_cents": 89451,
      "reserve_released_cents": 0,
      "paid_cents": 805057,
      "in_flight_cents": 0,
      "owed_cents": -6900,
      "after_release_cents": 82551,
      "reserve_release_due": true,
      "reserve_released_on": null,
      "reserve_skipped": false,
      "payout_account_ready": true,
      "settlement": null,
      "in_flight_payout": null,
      "currency": "usd"
    }
  ]
}
