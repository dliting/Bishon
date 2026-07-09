module.exports = {
  env: {
    node: true,
  },
  parser: 'vue-eslint-parser',
  parserOptions: {
    parser: '@typescript-eslint/parser',
    sourceType: 'module',
  },
  extends: [
    'eslint:recommended',
    'plugin:vue/vue3-recommended',
    'prettier',
    'plugin:prettier/recommended',
    './.eslintrc-auto-import',
  ],
  plugins: ['prettier', '@typescript-eslint'],
  rules: {
    'no-console': process.env.NODE_ENV === 'production' ? 'warn' : 'off',
    'no-debugger': process.env.NODE_ENV === 'production' ? 'warn' : 'off',
    semi: 'error',
    'max-len': 'off',
    'no-tabs': 'off',
    'linebreak-style': [0, 'error', 'windows'],
    'no-underscore-dangle': ['off', 'always'],
    'no-unused-vars': 'off',
    '@typescript-eslint/no-unused-vars': ['error'],
    'vue/no-v-html': 'off',
  },
};
