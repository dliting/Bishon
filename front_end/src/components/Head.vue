<template>
  <div class="header">
    <div class="logo">
      <img
        src="../assets/login/logo-small.png"
        alt="logo"
        @click="goDetail('https://github.com/dliting/Bishon')"
      />
    </div>
    <ul>
      <li class="toggle-button">
        <span :class="[language === 'zh' ? 'active' : '']" @click="changLanguage('zh')">中</span>
        <span class="line"></span>
        <span :class="[language === 'en' ? 'active' : '']" @click="changLanguage('en')">En</span>
      </li>
      <li>
        <a-popover placement="bottomRight" overlay-class-name="cooperate">
          <template #content>
            <p>{{ header.cooperationTips }}</p>
          </template>
          <template #title>
            <span>{{ header.cooperationMore }}</span>
          </template>
        </a-popover>
      </li>
    </ul>
    <div class="user">
      <img src="../assets/home/avatar.png" alt="头像" />
    </div>
  </div>
</template>
<script lang="ts" setup>
// import { useUser } from '@/store/useUser';
// const { userInfo } = storeToRefs(useUser());
import { useLanguage } from '@/store/useLanguage';
import { getLanguage } from '@/language/index';

const header = getLanguage().header;
const { language } = storeToRefs(useLanguage());
const { setLanguage } = useLanguage();

const changLanguage = (lang: string) => {
  setLanguage(lang);
  window.location.reload();
};

const goDetail = (url: string) => {
  console.log(url);
  window.location.href = url;
};
</script>
<style lang="scss" scoped>
.header {
  width: 100vw;
  min-width: 1200px;
  height: 64px;
  display: flex;
  align-items: center;
  background: #26293b;

  .logo {
    width: 146px;
    height: 28px;
    margin-left: 32px;
    cursor: pointer;

    img {
      width: 100%;
      height: 100%;
    }
  }
  .toggle-button {
    font-size: 14px;
    font-weight: 300;
    line-height: 22px;
    color: #cccccc;
    cursor: pointer;
    .active {
      color: #ffffff;
      font-weight: 500;
    }
    .line {
      width: 1px;
      height: 14px;
      border-left: 1px solid rgb(216, 216, 216, 0.3);
      margin: 0px 8px;
    }
  }
  ul {
    display: flex;
    margin-left: auto;
    margin-right: 32px;

    li {
      display: flex;
      align-items: center;
      margin-left: 56px;
      color: #ffffff;
      cursor: pointer;

      img {
        width: 16px;
        height: 16px;
        margin-right: 4px;
      }
    }

    .myspan {
      display: flex !important;
      align-items: center;
    }
  }

  .user {
    margin-right: 20px;
    width: 32px;
    height: 32px;
  }
}
</style>
