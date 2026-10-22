export const TAX_CLASSIFICATIONS = [
  ['individual', 'Individual / sole proprietor'], ['single_member_llc', 'Single-member LLC'],
  ['c_corp', 'C corporation'], ['s_corp', 'S corporation'], ['partnership', 'Partnership'],
  ['trust_estate', 'Trust / estate'], ['llc_c', 'LLC taxed as C corporation'],
  ['llc_s', 'LLC taxed as S corporation'], ['llc_p', 'LLC taxed as partnership'],
  ['nonprofit', 'Nonprofit / exempt'], ['government', 'Government'],
]

export const taxClassificationLabel = value => TAX_CLASSIFICATIONS.find(([key]) => key === value)?.[1] || value || 'Not provided'
