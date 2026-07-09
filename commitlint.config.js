module.exports = {
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor', 'test', 'chore', 'revert',
    ]],
    'subject-case': [0],
    'subject-empty': [2, 'never'],
    'type-empty': [2, 'never'],
  },
}
