// Match the PostgreSQL integer column used for event capacity.
export const MAX_EVENT_CAPACITY = 2147483647

export function validEventCapacity(value) {
  const capacity = Number(value)
  return Number.isSafeInteger(capacity) && capacity >= 1 && capacity <= MAX_EVENT_CAPACITY
}
