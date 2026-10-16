import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { postureApi } from './server/api.js';

export default defineConfig({
  plugins: [react(), tailwindcss(), postureApi()],
  server: { host: '127.0.0.1', port: 5173 },
});
