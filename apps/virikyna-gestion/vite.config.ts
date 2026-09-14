import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// PWA instalable en iOS (Safari → Compartir → Agregar a inicio) y en Mac (Chrome/Edge → Instalar) —
// docs/05_stack_tecnico.md sección 3. Sin SQLite/PowerSync: habla directo con Supabase.
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icons/icon-192.png', 'icons/icon-512.png'],
      manifest: {
        name: 'Virikyna Gestión',
        short_name: 'Gestión',
        description: 'Gestión completa del negocio — Virikyna (dueña).',
        start_url: '/',
        display: 'standalone',
        background_color: '#F7F6FA',
        theme_color: '#3FB9B9',
        icons: [
          { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
    }),
  ],
  server: {
    port: 1440,
  },
})
