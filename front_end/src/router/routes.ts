import { RouteRecordRaw } from 'vue-router';

export const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: () => import('@/layout/index.vue'),
    redirect: '/home',
    children: [
      {
        path: '/home',
        name: 'home',
        component: () => import('@/views/Home.vue'),
        meta: {
          title: '首页',
        },
      },
    ],
  },
  {
    path: '/:catchAll(.*)',
    redirect: '/home',
  },
];
