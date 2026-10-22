import { describe, expect, it } from 'vitest'
import { Briefcase, GraduationCap, HandHeart, Moon, Music, PartyPopper, Sparkles, Trophy, Users, UtensilsCrossed } from 'lucide-react'
import { CATEGORY_ICONS, categoryIcon } from './categoryIcons'

describe('category icons', () => {
  it('gives every API event category its own icon', () => {
    const apiCategories = ['nightlife', 'concert', 'festival', 'dining', 'sports', 'workshop', 'fundraiser', 'family', 'business', 'other']
    expect(Object.keys(CATEGORY_ICONS).sort()).toEqual([...apiCategories].sort())
    expect(apiCategories.map(categoryIcon)).toEqual([Moon, Music, PartyPopper, UtensilsCrossed, Trophy, GraduationCap, HandHeart, Users, Briefcase, Sparkles])
    expect(new Set(apiCategories.map(categoryIcon)).size).toBe(apiCategories.length)
  })

  it('falls back to a generic icon for categories added later', () => {
    expect(categoryIcon('something-new')).toBe(Sparkles)
  })
})
