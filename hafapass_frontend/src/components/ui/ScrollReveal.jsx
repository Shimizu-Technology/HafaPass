import { motion, useInView, useReducedMotion } from 'framer-motion';
import { useRef } from 'react';

const ease = [0, 0, 0.2, 1];

export const FadeUp = ({ children, delay = 0, className = '' }) => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: '-80px' });
  const reducedMotion = useReducedMotion();
  return (
    <motion.div
      ref={ref}
      initial={reducedMotion ? false : { opacity: 1, y: 8 }}
      animate={{ opacity: 1, y: reducedMotion || isInView ? 0 : 8 }}
      transition={{ duration: reducedMotion ? 0 : 0.22, delay: reducedMotion ? 0 : delay, ease }}
      className={className}
    >
      {children}
    </motion.div>
  );
};

export const StaggerContainer = ({ children, className = '' }) => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: '-80px' });
  const reducedMotion = useReducedMotion();
  return (
    <motion.div
      ref={ref}
      initial={reducedMotion ? false : 'resting'}
      animate={reducedMotion || isInView ? 'settled' : 'resting'}
      variants={{ resting: {}, settled: { transition: { staggerChildren: reducedMotion ? 0 : 0.04 } } }}
      className={className}
    >
      {children}
    </motion.div>
  );
};

export const StaggerItem = ({ children, className = '' }) => {
  const reducedMotion = useReducedMotion();
  return (
    <motion.div
      variants={{
        // Readable before the observer fires, including when it never fires.
        resting: { opacity: 1, y: reducedMotion ? 0 : 8 },
        settled: { opacity: 1, y: 0, transition: { duration: reducedMotion ? 0 : 0.22, ease } },
      }}
      className={className}
    >
      {children}
    </motion.div>
  );
};
