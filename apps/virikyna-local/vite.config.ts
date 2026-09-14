import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Config recomendada por Tauri v2 para el frontend: puerto fijo (matchea tauri.conf.json)
// e ignora src-tauri en el watcher para no reiniciar Vite en cada build de Rust.
const host = process.env.TAURI_DEV_HOST

export default defineConfig(async () => ({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: 'ws', host, port: 1421 } : undefined,
    watch: {
      ignored: ['**/src-tauri/**'],
    },
  },
}))
