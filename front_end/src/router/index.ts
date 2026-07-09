import { createRouter, createWebHashHistory } from 'vue-router';
import { routes } from './routes';
// import { useUser } from '@/store/useUser';
// Import the progress bar.
import { start, close } from '@/utils/nporgress';

// Whether to hide the nav bar.

const router = createRouter({
  history: createWebHashHistory(),
  routes,
});
router.beforeEach((to, from, next) => {
  start();
  next();
});

router.afterEach(() => {
  close();
});
export default router;
