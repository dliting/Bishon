import { createPinia } from 'pinia';
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate';

// Create.
const pinia = createPinia();
pinia.use(piniaPluginPersistedstate);
// Export.
export default pinia;
