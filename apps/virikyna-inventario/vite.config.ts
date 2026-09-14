import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import basicSsl from '@vitejs/plugin-basic-ssl'
import { VitePWA } from 'vite-plugin-pwa'

// PWA de uso puntual con cámara (docs/05_stack_tecnico.md, sección 2): sin SQLite/PowerSync,
// habla directo con Supabase. `basicSsl` + `host: true` sirven HTTPS en la red local para poder
// probar el escaneo de código de barras (getUserMedia exige contexto seguro) desde un celular real
// apuntando a la IP de la notebook — no solo desde el emulador del navegador de escritorio.
export default defineConfig({
  plugins: [
    react(),
    basicSsl(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icons/icon-192.png', 'icons/icon-512.png'],
      manifest: {
        name: 'Virikyna Inventario',
        short_name: 'Inventario',
        description: 'Inventario y carga de facturas de proveedor desde el celular — Virikyna.',
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
    host: true,
    port: 1430,
  },
})
