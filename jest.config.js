module.exports = {
  preset: '@react-native/jest-preset',

  // ⚠️ 为什么必须排除 src/core/__tests__：
  // 那三个文件**不是 jest 用例**。它们用自写的 `test(name, fn)` helper 搭了个
  // 迷你运行器，靠 `process.exitCode = 1` 表达失败，正确跑法是
  //   node --experimental-strip-types src/core/__tests__/<file>.test.ts
  // （见 package.json 的 test:core）。文件里没有任何 jest 的 it/describe 调用，
  // 所以 jest 一旦把它们收进来，每个套件都会报
  //   "Your test suite must contain at least one test"
  // 结果是 3 个套件全红、0 用例 —— 而实际上 84 条断言全都通过。
  // 后果很坏：npm test 恒定失败，CI 拿不到任何单测信号，
  // 还让人误以为「测试全挂了」。
  testPathIgnorePatterns: ['/node_modules/', '/src/core/__tests__/'],
};
