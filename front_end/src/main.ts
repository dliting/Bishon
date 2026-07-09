import { createApp } from 'vue';
import App from './App.vue';
import router from './router/index';
import pinia from './store/index';
import '@/styles/common/global.scss';
import 'virtual:svg-icons-register';
import SvgIcon from '@/components/SvgIcon.vue';

const vueApp = createApp(App);
vueApp.use(pinia).use(router);
vueApp.component('SvgIcon', SvgIcon);
vueApp.mount('#app');
