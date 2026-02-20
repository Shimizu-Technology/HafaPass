export const Skeleton = ({ className = '' }) => (
  <div className={`animate-pulse bg-neutral-200 dark:bg-neutral-800 rounded-lg ${className}`} />
);

export const EventCardSkeleton = () => (
  <div className="rounded-2xl border border-neutral-200 overflow-hidden">
    <Skeleton className="h-48 w-full rounded-none" />
    <div className="p-5">
      <Skeleton className="h-4 w-20 mb-3" />
      <Skeleton className="h-5 w-3/4 mb-3" />
      <Skeleton className="h-4 w-full mb-2" />
      <Skeleton className="h-4 w-2/3" />
    </div>
  </div>
);
