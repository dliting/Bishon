export const useUser = defineStore(
  'user',
  () => {
    const userInfo = ref({
      token: '',
    });

    const setUserInfo = info => {
      userInfo.value = info;
    };

    return {
      userInfo,
      setUserInfo,
    };
  },
  {
    persist: {
      storage: localStorage,
    },
  }
);
