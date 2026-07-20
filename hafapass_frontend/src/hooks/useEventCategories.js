import { useEffect, useState } from 'react'
import apiClient from '../api/client'

const FALLBACK_CATEGORIES = [
  { value: 'nightlife', label: 'Nightlife' },
  { value: 'concert', label: 'Music & Concerts' },
  { value: 'festival', label: 'Festivals & Culture' },
  { value: 'dining', label: 'Food & Drink' },
  { value: 'sports', label: 'Sports & Fitness' },
  { value: 'workshop', label: 'Classes & Workshops' },
  { value: 'fundraiser', label: 'Fundraisers & Nonprofits' },
  { value: 'family', label: 'Family' },
  { value: 'business', label: 'Business & Networking' },
  { value: 'other', label: 'Other' },
]

export default function useEventCategories() {
  const [categories, setCategories] = useState(FALLBACK_CATEGORIES)

  useEffect(() => {
    apiClient.get('/event_categories')
      .then(response => {
        if (Array.isArray(response.data?.categories) && response.data.categories.length) {
          setCategories(response.data.categories)
        }
      })
      .catch(() => {})
  }, [])

  return categories
}
