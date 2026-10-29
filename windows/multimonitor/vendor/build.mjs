import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
await build({
  stdin: { contents: 'export * from "zebar";', resolveDir: fileURLToPath(new URL('.', import.meta.url)) },
  bundle: true, format: 'esm', minify: true, legalComments: 'eof',
  outfile: fileURLToPath(new URL('./zebar.js', import.meta.url)),
});
