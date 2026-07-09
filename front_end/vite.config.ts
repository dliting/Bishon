import { defineConfig, loadEnv } from 'vite';
import vue from '@vitejs/plugin-vue';
import eslintPlugin from 'vite-plugin-eslint';
import path from 'path';
import fs from 'fs';
// On-demand loading for antd-vue.
import Components from 'unplugin-vue-components/vite';
import { AntDesignVueResolver } from 'unplugin-vue-components/resolvers';
// No need to manually import ref, etc.
import AutoImport from 'unplugin-auto-import/vite';
// SVG-related plugin.
import { createSvgIconsPlugin } from 'vite-plugin-svg-icons';

function readFolder(entryPath, callback) {
  // Recursively read all file paths under the entry folder.
  const files = fs.readdirSync(path.resolve(__dirname, entryPath));
  files.forEach(file => {
    const filePath = path.resolve(__dirname, `${entryPath}/${file}`); // absolute path of the file
    const stat = fs.lstatSync(filePath);
    if (stat.isDirectory()) {
      // It's a directory.
      readFolder(filePath, callback);
    } else {
      callback(entryPath, file);
    }
  });
}
// Get the file extension.
function getExtname(allPath) {
  return path.extname(allPath);
}
//
const additionalData = (function () {
  let resources = '';
  const styleFolderPath = path.resolve(__dirname, './src/styles/variable');
  readFolder(styleFolderPath, (filePath, file) => {
    const allPath = `@import "@styles/variable/${file}`;
    const extname = getExtname(allPath);
    if (extname === '.scss') {
      resources = `${allPath}";${resources}`; // put setting first
    }
  });
  return resources;
})();
const plugins = [] as any;

function resovePath(paths) {
  return path.resolve(__dirname, paths);
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd());

  return {
    plugins: [
      Components({
        resolvers: [
          AntDesignVueResolver({
            importStyle: false, // css in js
          }),
        ],
      }),
      AutoImport({
        imports: ['vue', 'vue-router', 'pinia'],
        // The config below generates the auto-import eslint rule JSON. After generation,
        // set enabled=false to avoid regenerating; eslint extend imports the generated JSON rules.
        dts: './auto-imports.d.ts',
        eslintrc: {
          enabled: true,
        },
      }),
      vue(),
      eslintPlugin(),
      createSvgIconsPlugin({
        // Specify the icon folders to cache.
        iconDirs: [path.resolve(process.cwd(), 'src/assets/svg')],
        // Specify the symbolId format.
        symbolId: 'icon-[name]',
        // inject: 'body-last' | 'body-first',
        inject: 'body-last',
        customDomId: '__svg__icons__dom__',
      }),

      ...plugins,
    ],
    resolve: {
      // Configure path aliases.
      alias: {
        '@': resovePath('src'),
        '@views/': resovePath('src/views'),
        '@comps': resovePath('./src/components'),
        '@imgs': resovePath('./src/assets/img'),
        '@icons': resovePath('./src/assets/icons'),
        '@utils': resovePath('./src/utils'),
        '@stores': resovePath('./src/store'),
        '@plugins': resovePath('./src/plugins'),
        '@styles': resovePath('./src/styles'),
      },
    },
    css: {
      preprocessorOptions: {
        scss: {
          additionalData,
        },
        less: {
          javascriptEnabled: true,
        },
      },
    },
    build: {
      outDir: `dist/bishon`,
    },

    base: env.VITE_APP_WEB_PREFIX,
    server: {
      usePolling: true,
      port: 5052,
      host: '0.0.0.0',
      open: false,
      fs: {
        strict: false,
      },
      cors: true,
      proxy: {
        [env.VITE_APP_API_PREFIX]: {
		      target: env.VITE_APP_API_HOST + env.VITE_APP_API_PREFIX,
          changeOrigin: true,
		      secure: false,
        },
      },
    },
  };
});
