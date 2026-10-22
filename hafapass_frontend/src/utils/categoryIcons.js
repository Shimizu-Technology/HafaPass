import { Briefcase, GraduationCap, HandHeart, Moon, Music, PartyPopper, Sparkles, Trophy, Users, UtensilsCrossed } from 'lucide-react'

// One icon per Event category enum value (see Event::CATEGORY_LABELS in the API).
export const CATEGORY_ICONS = {
  nightlife: Moon,
  concert: Music,
  festival: PartyPopper,
  dining: UtensilsCrossed,
  sports: Trophy,
  workshop: GraduationCap,
  fundraiser: HandHeart,
  family: Users,
  business: Briefcase,
  other: Sparkles,
}

export function categoryIcon(value) {
  return CATEGORY_ICONS[value] || Sparkles
}
